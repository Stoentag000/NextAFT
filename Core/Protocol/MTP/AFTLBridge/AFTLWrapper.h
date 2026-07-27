//
//  AFTLWrapper.h
//  NextAFT
//
//  Pure C bridge to android-file-transfer-linux (C++ library).
//  Swift calls these functions; internally they delegate to C++ AFTL classes.
//

#ifndef AFTLWrapper_h
#define AFTLWrapper_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque handle — wraps mtp::Device + mtp::Session + path cache
// ---------------------------------------------------------------------------
typedef void *AFTLSessionRef;

typedef void (*AFTLProgressCallback)(double progress, void *userdata);
typedef bool (*AFTLCancellationCallback)(void *userdata);

// ---------------------------------------------------------------------------
// File info returned by aftl_list_files
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t object_id;   // MTP object ID (used for download/delete/mkdir)
    char    *name;        // heap-allocated, freed by aftl_free_file_list
    uint64_t size;        // file size in bytes (0 for directories)
    bool     is_directory;
} AFTLFileInfo;

typedef struct {
    AFTLFileInfo *items;
    int           count;
} AFTLFileList;

// ---------------------------------------------------------------------------
// Device info
// ---------------------------------------------------------------------------
typedef struct {
    char *manufacturer;
    char *model;
    char *serial;
    char *storage_description;  // e.g. "32 GB, 18 GB free"
    uint64_t storage_total;
    uint64_t storage_free;
} AFTLDeviceInfo;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Detect the first MTP device and open a session.
/// Returns NULL on failure.  Call aftl_disconnect() when done.
AFTLSessionRef aftl_connect(void);

/// Close session and release all resources.
void aftl_disconnect(AFTLSessionRef session);

/// Returns true if the handle is valid (non-NULL).
bool aftl_is_connected(AFTLSessionRef session);

// ---------------------------------------------------------------------------
// Device information
// ---------------------------------------------------------------------------

/// Caller must call aftl_free_device_info() on the returned struct.
AFTLDeviceInfo aftl_get_device_info(AFTLSessionRef session);
void           aftl_free_device_info(AFTLDeviceInfo *info);

/// Human-readable detail for the most recent failure on the calling thread.
/// The returned pointer remains valid until the next AFTL wrapper call on that thread.
const char    *aftl_last_error(void);

// ---------------------------------------------------------------------------
// File listing
// ---------------------------------------------------------------------------

/// List files at the given MTP path (e.g. "/storage/emulated/0/DCIM").
/// On success returns 0 and fills *out; caller must call aftl_free_file_list().
/// On failure returns non-zero error code.
int aftl_list_files(AFTLSessionRef session, const char *path,
                    AFTLFileList *out);

void aftl_free_file_list(AFTLFileList *list);

// ---------------------------------------------------------------------------
// Transfer
// ---------------------------------------------------------------------------

/// Download a remote file (by object ID) to a local path.
/// progress_cb receives values in [0.0, 1.0]; may be NULL.
/// Returns 0 on success.
int aftl_download(AFTLSessionRef session, uint32_t object_id,
                  const char *local_path,
                  AFTLProgressCallback progress_cb, void *progress_userdata,
                  AFTLCancellationCallback cancellation_cb,
                  void *cancellation_userdata, uint64_t transfer_id);

/// Upload a local file with remote_name to the given parent directory (by object ID).
/// Returns 0 on success; fills *new_object_id if non-NULL.
int aftl_upload(AFTLSessionRef session, const char *local_path,
                const char *remote_name, uint32_t parent_object_id,
                AFTLProgressCallback progress_cb, void *progress_userdata,
                AFTLCancellationCallback cancellation_cb,
                void *cancellation_userdata, uint64_t transfer_id,
                uint32_t *new_object_id);

/// Cancel the matching active transfer. Safe to call from another thread.
/// Returns 0 when cancellation was delivered, 1 if it already ended.
int aftl_cancel_transfer(AFTLSessionRef session, uint64_t transfer_id);

// ---------------------------------------------------------------------------
// File operations
// ---------------------------------------------------------------------------

/// Delete a remote object (file or empty directory).
int aftl_delete(AFTLSessionRef session, uint32_t object_id);

/// Create a subdirectory under parent_object_id.
/// Returns 0 on success; fills *new_dir_id if non-NULL.
int aftl_mkdir(AFTLSessionRef session, const char *name,
               uint32_t parent_object_id, uint32_t *new_dir_id);

// ---------------------------------------------------------------------------
// Path resolution helpers
// ---------------------------------------------------------------------------

/// Resolve a full path (e.g. "/storage/emulated/0") to its MTP object ID.
/// Returns 0 on success and fills *object_id.
int aftl_resolve_path(AFTLSessionRef session, const char *path,
                      uint32_t *object_id);

/// Get the root object ID (usually the storage root).
uint32_t aftl_get_root_object_id(AFTLSessionRef session);

#ifdef __cplusplus
}
#endif

#endif /* AFTLWrapper_h */
