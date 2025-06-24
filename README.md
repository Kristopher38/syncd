# Syncd

Syncd is an OpenComputers daemon capable of synchronizing files between your local PC and your OpenComputers computer.
It consists of two parts:
1. Filesystem watcher written in Rust that notifies OC computer of any changes to the local filesystem
2. rc.d script written in Lua that runs in the background on your OC computer and updates the OC filesystem based on notifications coming from filesystem watcher

Currently only one directory can be synchronized and only from your local PC to your OC computer.
Filesystem watcher and rc.d script connect to each other through a [STEM bridge](https://gitlab.com/UnicornFreedom/stem).

## Setup

On your local machine the hardcoded synchronized directory is `watchdir` and it has to exist.

```
mkdir watchdir
cargo run
```

On your OC computer you need OpenOS and OPPM installed.

To install syncd package:
```
oppm register ShadowKatStudios/OC-Minitel
oppm register Kristopher38/syncd
oppm install syncd
```

Start the syncd daemon:
```
rc syncd start
```

This will create a config file under `/etc/syncd.cfg`.
It contains the following options:
- `channel` - unique name that needs to be configured to the same string for both sides to sync files. Currently has to be `"default_channel"`.
- `address` - address of a STEM server to connect to. Default is `"stem.fomalhaut.me:5733"`.
- `backend` - backend used for connection. Currently only support STEM. Default is `"stem"`.
- `backendOps` - extra parameters to pass to the backend. Default is `{}`.
- `syncedDir` - Path to directory where synced files will be stored in. Must be an absolute path. Default is `"/home/default_dir"`.

You should adjust `syncedDir` accordingly and restart the service:

```
rc syncd restart
```

At this point files and directories created locally should show up on your OC computer.

