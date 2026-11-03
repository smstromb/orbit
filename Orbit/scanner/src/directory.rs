//! macOS returns names and file metadata together with getattrlistbulk(2).
//! The portable path is retained for unsupported filesystems and A/B checks.
use std::{
    ffi::CString,
    fs, io,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawFd,
    },
    path::Path,
};

#[derive(Debug)]
pub struct Entry {
    pub name: String,
    pub device: u64,
    pub inode: u64,
    pub logical: u64,
    pub allocated: u64,
    pub links: u64,
    pub kind: &'static str,
}

fn metadata_entry(path: &Path, name: String) -> io::Result<Entry> {
    let m = fs::symlink_metadata(path)?;
    Ok(Entry {
        name,
        device: m.dev(),
        inode: m.ino(),
        logical: m.len(),
        allocated: m.blocks().saturating_mul(512),
        links: m.nlink(),
        kind: if m.file_type().is_symlink() {
            "link"
        } else if m.is_dir() {
            "folder"
        } else if m.is_file() {
            "file"
        } else {
            "special"
        },
    })
}

pub fn read(
    path: &Path,
    portable: bool,
    mut emit: impl FnMut(Vec<Entry>, u64) -> io::Result<()>,
) -> io::Result<()> {
    // access(2) rejects protected app containers without opening them. Opening
    // them directly can block a worker on macOS's interactive privacy checks.
    let c_path = CString::new(path.as_os_str().as_bytes()).map_err(|_| malformed())?;
    // SAFETY: c_path is a live, NUL-terminated filesystem path. R_OK | X_OK = 5.
    if unsafe { access(c_path.as_ptr(), 5) } != 0 {
        return Err(io::Error::last_os_error());
    }
    if !portable {
        match bulk(path, &mut emit) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::Unsupported => {}
            Err(e) => return Err(e),
        }
    }
    let mut entries = Vec::with_capacity(512);
    let mut issues = 0;
    for item in fs::read_dir(path)? {
        let item = match item {
            Ok(x) => x,
            Err(_) => {
                issues += 1;
                continue;
            }
        };
        let name = match item.file_name().into_string() {
            Ok(x) => x,
            Err(_) => {
                issues += 1;
                continue;
            }
        };
        match metadata_entry(&item.path(), name) {
            Ok(x) => entries.push(x),
            Err(_) => issues += 1,
        }
        if entries.len() >= 512 {
            emit(
                std::mem::replace(&mut entries, Vec::with_capacity(512)),
                issues,
            )?;
            issues = 0;
        }
    }
    if !entries.is_empty() || issues > 0 {
        emit(entries, issues)?;
    }
    Ok(())
}

#[repr(C)]
struct AttrList {
    count: u16,
    reserved: u16,
    common: u32,
    volume: u32,
    directory: u32,
    file: u32,
    fork: u32,
}
unsafe extern "C" {
    fn access(path: *const std::ffi::c_char, mode: i32) -> i32;
    fn getattrlistbulk(
        fd: i32,
        list: *mut AttrList,
        buffer: *mut std::ffi::c_void,
        size: usize,
        options: u64,
    ) -> i32;
}
const NAME: u32 = 1;
const DEVICE: u32 = 2;
const TYPE: u32 = 8;
const FLAGS: u32 = 0x0004_0000;
const FILE_ID: u32 = 0x0200_0000;
const ERROR: u32 = 0x2000_0000;
const RETURNED: u32 = 0x8000_0000;
const LINK_COUNT: u32 = 1;
const ALLOCATION: u32 = 4;
const LENGTH: u32 = 0x200;
const MOUNT_STATUS: u32 = 4;

fn u32_at(data: &[u8], at: usize) -> io::Result<u32> {
    data.get(at..at + 4)
        .map(|x| u32::from_ne_bytes(x.try_into().unwrap()))
        .ok_or_else(malformed)
}
fn u64_at(data: &[u8], at: usize) -> io::Result<u64> {
    data.get(at..at + 8)
        .map(|x| u64::from_ne_bytes(x.try_into().unwrap()))
        .ok_or_else(malformed)
}
fn malformed() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Invalid bulk directory metadata",
    )
}

fn bulk(path: &Path, emit: &mut impl FnMut(Vec<Entry>, u64) -> io::Result<()>) -> io::Result<()> {
    // O_NOFOLLOW | O_DIRECTORY. Symlinks discovered during enumeration are never opened.
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(0x0010_0100)
        .open(path)?;
    let mut attrs = AttrList {
        count: 5,
        reserved: 0,
        common: RETURNED | ERROR | NAME | DEVICE | TYPE | FLAGS | FILE_ID,
        volume: 0,
        directory: MOUNT_STATUS,
        file: LINK_COUNT | ALLOCATION | LENGTH,
        fork: 0,
    };
    // u64 storage satisfies the API's 8-byte record alignment.
    let mut buffer = vec![0u64; 256 * 1024 / 8];
    let mut first = true;
    loop {
        // SAFETY: list and aligned buffer remain valid for the full synchronous syscall.
        // All offsets returned by the kernel are checked against the record below.
        let count = unsafe {
            getattrlistbulk(
                file.as_raw_fd(),
                &mut attrs,
                buffer.as_mut_ptr().cast(),
                buffer.len() * 8,
                8,
            )
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if first && matches!(error.raw_os_error(), Some(22 | 45 | 78)) {
                return Err(io::Error::new(io::ErrorKind::Unsupported, error));
            }
            return Err(error);
        }
        if count == 0 {
            return Ok(());
        }
        first = false;
        // SAFETY: every byte is initialized by the zero-filled allocation, and immutable here.
        let data =
            unsafe { std::slice::from_raw_parts(buffer.as_ptr().cast::<u8>(), buffer.len() * 8) };
        let mut offset = 0;
        let mut entries = Vec::with_capacity(count as usize);
        let mut issues = 0;
        for _ in 0..count {
            let length = u32_at(data, offset)? as usize;
            if length < 56 {
                return Err(malformed());
            }
            let record = data
                .get(offset..offset.checked_add(length).ok_or_else(malformed)?)
                .ok_or_else(malformed)?;
            offset += length;
            let common = u32_at(record, 4)?;
            let directory = u32_at(record, 12)?;
            let file_attrs = u32_at(record, 16)?;
            // FSOPT_PACK_INVAL_ATTRS fixes the offsets even for inapplicable file/dir fields.
            // ATTR_CMN_ERROR is specially placed immediately after returned attributes.
            if u32_at(record, 24)? != 0 || common & NAME == 0 {
                issues += 1;
                continue;
            }
            let name_offset = u32_at(record, 28)? as i32;
            let name_len = u32_at(record, 32)? as usize;
            let name_start = 28i64 + i64::from(name_offset);
            if name_start < 0 || name_len == 0 {
                return Err(malformed());
            }
            let start = name_start as usize;
            let raw_name = record
                .get(start..start.checked_add(name_len).ok_or_else(malformed)?)
                .ok_or_else(malformed)?;
            if raw_name.last() != Some(&0) {
                return Err(malformed());
            }
            let name = match std::str::from_utf8(&raw_name[..raw_name.len() - 1]) {
                Ok(x) => x.to_owned(),
                Err(_) => {
                    issues += 1;
                    continue;
                }
            };
            if name == "." || name == ".." {
                continue;
            }
            let device = u32_at(record, 36)? as u64;
            let objtype = u32_at(record, 40)?;
            let flags = u32_at(record, 44)?;
            let inode = u64_at(record, 48)?;
            let mount = if objtype == 2 { u32_at(record, 56)? } else { 0 };
            // Inapplicable attribute *groups* are omitted even with PACK_INVAL_ATTRS.
            let (links, allocated, logical) = if objtype == 1
                && file_attrs & (LINK_COUNT | ALLOCATION | LENGTH)
                    == LINK_COUNT | ALLOCATION | LENGTH
            {
                (
                    u32_at(record, 56)? as u64,
                    u64_at(record, 60)?,
                    u64_at(record, 68)?,
                )
            } else {
                (0, 0, 0)
            };
            // Bulk reports the *underlying* entry for mount points and firmlinks.
            // Resolve those exceptional entries with lstat before device/inode checks.
            let special =
                directory & MOUNT_STATUS != 0 && mount & 1 != 0 || flags & 0x0080_0000 != 0;
            if special
                || objtype == 5
                || common & (DEVICE | TYPE | FILE_ID) != DEVICE | TYPE | FILE_ID
                || objtype == 1
                    && file_attrs & (LINK_COUNT | ALLOCATION | LENGTH)
                        != LINK_COUNT | ALLOCATION | LENGTH
            {
                match metadata_entry(&path.join(&name), name) {
                    Ok(x) => entries.push(x),
                    Err(_) => issues += 1,
                }
            } else {
                entries.push(Entry {
                    name,
                    device,
                    inode,
                    logical,
                    allocated,
                    links,
                    kind: match objtype {
                        1 => "file",
                        2 => "folder",
                        _ => "special",
                    },
                });
            }
        }
        emit(entries, issues)?;
    }
}
