mod directory;
use std::{
    collections::{HashSet, VecDeque},
    env, fs,
    io::{self, BufWriter, Write},
    os::unix::fs::MetadataExt,
    path::PathBuf,
    sync::{Arc, Condvar, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

#[derive(Debug)]
struct Node {
    name: String,
    parent: Option<usize>,
    logical: u64,
    allocated: u64,
    kind: &'static str,
    files: u64,
    folders: u64,
    issues: u64,
}

fn quoted(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < '\u{20}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[derive(Clone)]
struct Task {
    path: PathBuf,
    parent: usize,
}
struct Batch {
    task: Task,
    entries: Vec<directory::Entry>,
    issues: u64,
    done: bool,
}
#[derive(Default)]
struct Queue {
    tasks: VecDeque<Task>,
    closed: bool,
    running: Vec<Option<(Instant, PathBuf)>>,
}

fn report_progress(
    out: &mut impl Write,
    files: u64,
    bytes: u64,
    allocated: u64,
    workers: usize,
    path: &std::path::Path,
    waiting: bool,
) -> io::Result<()> {
    writeln!(
        out,
        "{{\"type\":\"progress\",\"files\":{files},\"bytes\":{bytes},\"allocated\":{allocated},\"workers\":{workers},\"waiting\":{waiting},\"path\":{}}}",
        quoted(&path.to_string_lossy())
    )?;
    out.flush()
}

fn scan(
    root: PathBuf,
    workers: usize,
    portable: bool,
    summary: bool,
    binary: bool,
    mut out: impl Write,
) -> io::Result<()> {
    let started = Instant::now();
    let root = fs::canonicalize(root)?;
    let meta = fs::metadata(&root)?;
    if !meta.is_dir() {
        return Err(io::Error::other("Choose a folder to scan."));
    }
    let root_device = meta.dev();
    let whole_disk = root == std::path::Path::new("/");
    let mut nodes = vec![Node {
        name: root
            .file_name()
            .map(|x| x.to_string_lossy().into_owned())
            .unwrap_or("Macintosh HD".into()),
        parent: None,
        logical: 0,
        allocated: 0,
        kind: "folder",
        files: 0,
        folders: 0,
        issues: 0,
    }];
    let mut files_seen = HashSet::new();
    let mut dirs_seen = HashSet::from([(meta.dev(), meta.ino())]);
    let queue = Arc::new((
        Mutex::new(Queue {
            tasks: VecDeque::from([Task {
                path: root.clone(),
                parent: 0,
            }]),
            closed: false,
            running: vec![None; workers],
        }),
        Condvar::new(),
    ));
    // Workers own their directory handles/buffers. Only this coordinator writes the tree
    // and inode sets; no per-file locking, concurrent tree mutation, or shared writer.
    let (send, receive) = mpsc::sync_channel::<Batch>(workers * 2);
    let mut threads = Vec::new();
    for worker_index in 0..workers {
        let queue = queue.clone();
        let send = send.clone();
        threads.push(thread::spawn(move || {
            loop {
                let task = {
                    let (lock, ready) = &*queue;
                    let mut state = lock.lock().unwrap();
                    state.running[worker_index] = None;
                    while state.tasks.is_empty() && !state.closed {
                        state = ready.wait(state).unwrap();
                    }
                    if state.closed {
                        break;
                    }
                    let task = state.tasks.pop_front().unwrap();
                    state.running[worker_index] = Some((Instant::now(), task.path.clone()));
                    task
                };
                let result = directory::read(&task.path, portable, |entries, issues| {
                    send.send(Batch {
                        task: task.clone(),
                        entries,
                        issues,
                        done: false,
                    })
                    .map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe))
                });
                if send
                    .send(Batch {
                        task,
                        entries: Vec::new(),
                        issues: u64::from(result.is_err()),
                        done: true,
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
    }
    drop(send);
    let mut active = 1usize;
    let mut file_count = 0u64;
    let mut byte_count = 0u64;
    let mut allocated_count = 0u64;
    let mut last_progress = Instant::now() - Duration::from_secs(1);
    let scan_result = (|| -> io::Result<()> {
        while active > 0 {
            let batch = match receive.recv_timeout(Duration::from_millis(500)) {
                Ok(batch) => batch,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::other("Scan workers stopped unexpectedly"));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    let oldest = queue
                        .0
                        .lock()
                        .unwrap()
                        .running
                        .iter()
                        .flatten()
                        .min_by_key(|(started, _)| *started)
                        .cloned();
                    if let Some((since, path)) = oldest
                        && since.elapsed() >= Duration::from_secs(2)
                    {
                        report_progress(
                            &mut out,
                            file_count,
                            byte_count,
                            allocated_count,
                            workers,
                            &path,
                            true,
                        )?;
                        last_progress = Instant::now();
                    }
                    continue;
                }
            };
            let parent = batch.task.parent;
            nodes[parent].issues += batch.issues;
            let mut tasks = Vec::new();
            for entry in batch.entries {
                let id = nodes.len();
                let mut node = Node {
                    name: entry.name,
                    parent: Some(parent),
                    logical: 0,
                    allocated: 0,
                    kind: entry.kind,
                    files: 0,
                    folders: 0,
                    issues: 0,
                };
                if entry.kind == "link" {
                    node.logical = entry.logical;
                    node.allocated = entry.allocated;
                    node.files = 1;
                    file_count += 1;
                    byte_count = byte_count.saturating_add(entry.logical);
                } else if entry.device != root_device {
                    node.kind = "boundary";
                    node.issues = 1;
                } else if entry.kind == "folder" {
                    node.folders = 1;
                    // APFS exposes the Data volume both here and through /Users, /Library,
                    // etc. Traverse the visible root paths once, never the alias again.
                    let volume_alias = whole_disk
                        && batch.task.path == std::path::Path::new("/System")
                        && node.name == "Volumes";
                    if volume_alias {
                        node.kind = "boundary";
                        node.issues = 1;
                    } else if dirs_seen.insert((entry.device, entry.inode)) {
                        tasks.push(Task {
                            path: batch.task.path.join(&node.name),
                            parent: id,
                        });
                        active += 1;
                    } else {
                        node.kind = "boundary";
                        node.issues = 1;
                    }
                } else if entry.kind == "file" {
                    node.logical = entry.logical;
                    node.files = 1;
                    file_count += 1;
                    if entry.links == 1 || files_seen.insert((entry.device, entry.inode)) {
                        node.allocated = entry.allocated;
                    }
                    byte_count = byte_count.saturating_add(node.logical);
                }
                allocated_count = allocated_count.saturating_add(node.allocated);
                nodes.push(node);
            }
            if !tasks.is_empty() {
                let (lock, ready) = &*queue;
                lock.lock().unwrap().tasks.extend(tasks);
                ready.notify_all();
            }
            if batch.done {
                active -= 1;
            }
            if last_progress.elapsed() >= Duration::from_millis(180) {
                report_progress(
                    &mut out,
                    file_count,
                    byte_count,
                    allocated_count,
                    workers,
                    &batch.task.path,
                    false,
                )?;
                last_progress = Instant::now();
            }
        }
        Ok(())
    })();
    {
        let (lock, ready) = &*queue;
        lock.lock().unwrap().closed = true;
        ready.notify_all();
    }
    drop(receive);
    for worker in threads {
        if worker.join().is_err() {
            return Err(io::Error::other("A scan worker failed"));
        }
    }
    scan_result?;
    for i in (1..nodes.len()).rev() {
        let parent = nodes[i].parent.unwrap();
        let (l, a, f, d, e) = (
            nodes[i].logical,
            nodes[i].allocated,
            nodes[i].files,
            nodes[i].folders,
            nodes[i].issues,
        );
        nodes[parent].logical = nodes[parent].logical.saturating_add(l);
        nodes[parent].allocated = nodes[parent].allocated.saturating_add(a);
        nodes[parent].files += f;
        nodes[parent].folders += d;
        nodes[parent].issues += e;
    }
    let elapsed = started.elapsed().as_secs_f64();
    let engine = if portable { "portable" } else { "macOS bulk" };
    if binary && !summary {
        if nodes.len() >= u32::MAX as usize {
            return Err(io::Error::other("Too many entries for the scan format"));
        }
        writeln!(
            out,
            "{{\"type\":\"binary\",\"version\":1,\"root\":{},\"elapsed\":{elapsed},\"workers\":{workers},\"engine\":{},\"nodeCount\":{}}}",
            quoted(&root.to_string_lossy()),
            quoted(engine),
            nodes.len()
        )?;
        // Each record is a 31-byte little-endian header followed by UTF-8 name bytes.
        // Counts are reconstructed from topology, avoiding two repeated u64 fields.
        for n in &nodes {
            let name_len = u16::try_from(n.name.len())
                .map_err(|_| io::Error::other("Filename too long for the scan format"))?;
            let kind = match n.kind {
                "folder" => 0,
                "file" => 1,
                "link" => 2,
                "boundary" => 3 | if n.folders > 0 { 0x80 } else { 0 },
                _ => 4,
            };
            out.write_all(&n.parent.map(|p| p as u32).unwrap_or(u32::MAX).to_le_bytes())?;
            out.write_all(&name_len.to_le_bytes())?;
            out.write_all(&[kind])?;
            out.write_all(&n.logical.to_le_bytes())?;
            out.write_all(&n.allocated.to_le_bytes())?;
            out.write_all(&n.issues.to_le_bytes())?;
            out.write_all(n.name.as_bytes())?;
        }
        return out.flush();
    }
    write!(
        out,
        "{{\"type\":\"result\",\"root\":{},\"elapsed\":{elapsed},\"workers\":{workers},\"engine\":{},\"nodeCount\":{},\"nodes\":[",
        quoted(&root.to_string_lossy()),
        quoted(engine),
        nodes.len()
    )?;
    let reported = if summary { &nodes[..1] } else { &nodes[..] };
    for (i, n) in reported.iter().enumerate() {
        if i > 0 {
            write!(out, ",")?;
        }
        write!(
            out,
            "{{\"name\":{},\"parent\":{},\"logical\":{},\"allocated\":{},\"kind\":{},\"files\":{},\"folders\":{},\"issues\":{}}}",
            quoted(&n.name),
            n.parent.map(|x| x.to_string()).unwrap_or("null".into()),
            n.logical,
            n.allocated,
            quoted(n.kind),
            n.files,
            n.folders,
            n.issues
        )?;
    }
    writeln!(out, "]}}")?;
    out.flush()
}

fn main() {
    let mut args = env::args_os().skip(1);
    let Some(path) = args.next() else {
        eprintln!("Usage: orbit-scan FOLDER [--workers N] [--portable] [--summary]");
        std::process::exit(2);
    };
    let mut workers = thread::available_parallelism()
        .map(|x| x.get())
        .unwrap_or(4)
        .clamp(1, 12);
    let mut portable = false;
    let mut summary = false;
    let mut binary = false;
    while let Some(option) = args.next() {
        if option == "--portable" {
            portable = true;
        } else if option == "--summary" {
            summary = true;
        } else if option == "--binary" {
            binary = true;
        } else if option == "--workers" {
            workers = args
                .next()
                .and_then(|s| s.to_str().and_then(|s| s.parse::<usize>().ok()))
                .filter(|n| (1..=32).contains(n))
                .unwrap_or_else(|| {
                    eprintln!("Workers must be between 1 and 32");
                    std::process::exit(2)
                });
        } else {
            eprintln!("Unknown option: {}", option.to_string_lossy());
            std::process::exit(2);
        }
    }
    if let Err(e) = scan(
        PathBuf::from(path),
        workers,
        portable,
        summary,
        binary,
        BufWriter::with_capacity(256 * 1024, io::stdout().lock()),
    ) {
        if e.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("{e}");
        }
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn escapes_json_names() {
        assert_eq!(quoted("a\n\"b\\c\t"), "\"a\\n\\\"b\\\\c\\t\"");
    }
}
