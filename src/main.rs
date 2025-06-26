use tokio;
use tokio::sync::mpsc;
use tokio::net::TcpStream;
use std::path::{Path, PathBuf};
use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher, Event, EventKind};
use notify::event::{ModifyKind::*, CreateKind::*, RenameMode::*};
use tokio::runtime::Builder;
use tokio_util::codec::Framed;
use tokio_util::bytes::BytesMut;
use futures::{SinkExt, StreamExt};
use serde::{Serialize, Deserialize};
use ciborium;
use twox_hash::XxHash64;
use std::hash::Hasher;
use std::fs;
use std::fs::FileType;
use serde_with::{serde_as, Bytes};
use path_clean::PathClean;
use std::env;
use clap::Parser;

mod codec;
use crate::codec::{Codec, Package};

#[derive(Parser, Debug)]
#[command(author, version, about)]
struct Args {
    #[arg(long, default_value = "stem.fomalhaut.me:5733")]
    address: String,
    #[arg(long)]
    channel: String,
    #[arg(long, default_value = ".")]
    syncdir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum EntityType {
    File,
    Directory,
    Symlink,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ListRespEntry {
    path: PathBuf,
    hash: u64,
    entity: EntityType,
}

#[serde_as]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum Protocol {
    Ping,
    Pong,
    List {path: PathBuf},
    ListResp {entries: Vec<ListRespEntry>},
    Get {path: PathBuf},
    GetResp {path: PathBuf, #[serde_as(as = "Bytes")] contents: Vec<u8>},
    FsEventCreate {path: PathBuf, entity: EntityType},
    FsEventModify {path: PathBuf, hash: u64},
    FsEventRename {path_from: PathBuf, path_to: PathBuf},
    FsEventDelete {path: PathBuf},
    FsEventUnknown {path: PathBuf, entity: EntityType, hash: u64}
}

fn hash_file(path: &Path) -> u64 {
    let mut hasher = XxHash64::default();
    match fs::read(path) {
        Ok(data) => {
            hasher.write(&data);
            hasher.finish()
        },
        Err(e) => {
            eprintln!("Failed to read file '{}': {}", path.display(), e);
            0
        }
    }
}

fn path_escapes_dir(path: &Path, dir: &Path) -> bool {
    !path.starts_with(dir)
}

fn list_path(path: &Path) -> Vec<(PathBuf, FileType)> {
    let dirents = fs::read_dir(path).unwrap();
    let mut paths = Vec::new();
    for dirent in dirents {
        let dirent = dirent.unwrap();
        paths.push((dirent.path(), dirent.file_type().unwrap()));
    }
    paths
}

fn handle_message(message: Protocol, syncdir: &Path) -> Option<Protocol> {
    match message {
        Protocol::Ping => Some(Protocol::Pong),
        Protocol::List {path} => {
            println!("path is {}", path.display());
            let watchpath = syncdir.join(&path).clean();
            if path_escapes_dir(&watchpath, syncdir) {
                return None
            }
            let paths = list_path(watchpath.as_ref());
            let mut entries = Vec::new();
            for (listpath, ftype) in paths.iter() {
                let entity = if ftype.is_file() {
                    EntityType::File
                } else if ftype.is_dir() {
                    EntityType::Directory
                } else if ftype.is_symlink() {
                    EntityType::Symlink
                } else {
                    EntityType::File
                };
                let strippath = listpath.strip_prefix(&syncdir).expect("Path does not contain syncdir prefix");
                println!("Returning path {}", strippath.display());
                entries.push(ListRespEntry {
                    path: strippath.to_path_buf(),
                    hash: hash_file(listpath.as_ref()),
                    entity: entity
                });
            }
            Some(Protocol::ListResp{entries: entries})
        },
        Protocol::Get {path} => {
            let watchpath = syncdir.join(&path).clean();
            if path_escapes_dir(&watchpath, syncdir) {
                println!("Path escapes {}", watchpath.display());
                return None
            }
            match fs::read::<&Path>(watchpath.as_ref()) {
                Ok(data) => Some(Protocol::GetResp{path: path, contents: data}),
                Err(_) => {
                    println!("failed reading file {}", path.display());
                    None // TODO: report error?
                }
            }
        },
        _ => None
    }
}

fn handle_fs_event(event: Event, syncdir: &Path) -> Option<Protocol> {
    let fullpath = env::current_dir().expect("Failed getting cwd").join(syncdir);
    let path = &event.paths[0];
    let strippath = path.strip_prefix(&fullpath).expect("Path escapes watched directory").to_path_buf();

    println!("FS event, path {}, stripped path {}", path.display(), strippath.display());
    match event.kind {
        EventKind::Create(File) => Some(Protocol::FsEventCreate{path: strippath, entity: EntityType::File}),
        EventKind::Create(Folder) => Some(Protocol::FsEventCreate{path: strippath, entity: EntityType::Directory}),
        EventKind::Modify(Data(_)) => Some(Protocol::FsEventModify{hash: hash_file(path.as_ref()), path: strippath}), 
        EventKind::Modify(Name(Both)) => {
            let path_to = &event.paths[1];
            let strippath_to = path_to.strip_prefix(&fullpath).expect("Target path escapes watched directory").to_path_buf();
            Some(Protocol::FsEventRename{path_from: strippath, path_to: strippath_to})
        }
        EventKind::Remove(_) => Some(Protocol::FsEventDelete{path: strippath}),
        _ => None
    }
}

async fn event_handler<'a>(addr: String, syncdir: PathBuf, channel: String, mut rx_watcher: mpsc::Receiver<Event>) {
    let conn = TcpStream::connect(addr).await.unwrap();
    let mut framed_conn = Framed::new(conn, Codec);

    let chan = BytesMut::from(channel.as_str());
    let _ = framed_conn.send(Package::Subscribe(chan.clone())).await;

    while let true = tokio::select! {
        Some(result) = framed_conn.next() => {
            match result {
                // Respond to pings with pongs with the same payload
                Ok(Package::Ping(payload)) => {
                    let _  = framed_conn.send(Package::Pong(payload)).await;
                }
                Ok(Package::Message(channel, payload)) => {
                    let deserialized: Protocol = ciborium::de::from_reader(payload.as_ref()).unwrap();
                    if let Some(response) = handle_message(deserialized, syncdir.as_path()) {
                        let mut msg = Vec::new();
                        let _ = ciborium::ser::into_writer(&response, &mut msg);
                        let _ = framed_conn.send(Package::Message(channel, BytesMut::from(msg.as_slice()))).await;
                    }
                }
                // Do nothing for other messages (client is not interested in them)
                Ok(_) => {}
                Err(e) => {
                    println!("error {:?}", e);
                }
            };
            true
        }
        Some(event) = rx_watcher.recv() => {
            if let Some(response) = handle_fs_event(event, syncdir.as_path()) {
                let mut serialized = Vec::new();
                let _ = ciborium::ser::into_writer(&response, &mut serialized);
                let _ = framed_conn.send(Package::Message(chan.clone(), BytesMut::from(serialized.as_slice()))).await;
            }
            true
        }
        else => {
            false
        }
    } {}
}

fn main() {
    let args = Args::parse();
    let rt = Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .unwrap();

    let (tx, rx) = mpsc::channel(32);
    let mut watcher = RecommendedWatcher::new(move |res: Result<notify::event::Event, notify::Error>| {
        let _ = tx.blocking_send(res.unwrap());
    }, Config::default()).unwrap();
    
    watcher.watch(&args.syncdir, RecursiveMode::Recursive).unwrap();

    let handle = rt.spawn(event_handler(
        args.address.clone(),
        args.syncdir.clone(),
        args.channel.clone(),
        rx
    ));
    
    let _ = rt.block_on(handle);
}
