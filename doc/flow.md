# Syncd protocol

## Flow

1. Server/Client connects to the proxy on a specified channel
2. Server/Client sends a PING on join to let the other side know that it's connected
3. Receiver responds with PONG (only one PING-PONG exchange is necessary to establish communication but parties are expected to handle any reasonable amount)
4. Client sends LIST(".") to get a list of all files and directories in the root synced directory (and may send more LIST requests to get contents of subdirectories)
5. Server responds with LIST_RESP([(path, hash), ...]) containing a list of files and directories
    - each file has a xxHash64 hash included computed on its contents
    - directories don't have modification date included
6. Client compares the received list with their local filesystem (subject to change):
    - directories that are missing on the local filesystem are created
    - directories that are present on the local filesystem but not on the list are deleted
    - files that are present on the filesystem but not on the received list are deleted
    - files that are missing or modified on the local filesystem are downloaded using GET(path) and created in temporary location and then moved, replacing old files
        - GET only supports file paths
        - GETs with paths to directories should be rejected by the server and no response should be returned
    - no action is taken on files/directories that are present and unchanged on the local filesystem
7. For each requested file, server sends a GET_RESP(path, contents) response
8. Server must send a FS_EVENT notification for changes on its filesystem, where possible formats are:
    - FS_EVENT(CREATE, path, FILE/DIR) - file/directory has been created
    - FS_EVENT(MODIFY, path, hash) - file contents have been modified
    - FS_EVENT(RENAME, path_from, path_to) - file/directory has been renamed
    - FS_EVENT(DELETE, path) - file/directory has been deleted
    - FS_EVENT(UNKNOWN, path, FILE/DIR, hash) - file/directory has triggered an unknown event
        - if the path does not exist, server should issue DELETE event instead
        - hash is only valid when type is FILE
9. The client shall act appropriately:
    - on CREATE create file/directory
        - if subtree doesn't exist, create it
    - on MODIFY compare the hash and if it differs, request the path with GET(path)
    - on RENAME rename the file/directory on the local filesystem
        - if subtree doesn't exist, create it
    - on DELETE delete the file/directory
    - on UNKNOWN:
        - if FILE:
            - if file exists locally, compare and download if differs
            - if and file does not exist locally, download it
            - otherwise do nothing
        - if DIR:
            - if directory does not exist locally, create it (and download its contents?)
            - if directory exists locally, compare its contents and redownload as appropriate
