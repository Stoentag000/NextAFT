//
//  AFTLWrapper.cpp
//  NextAFT
//
//  C++ implementation of the AFTL bridge.
//  Links against libmtp-ng-static (android-file-transfer-linux).
//

#include "AFTLWrapper.h"

// Use relative paths pointing directly to the AFTL submodule source.
// Do NOT add Vendor/aftl-output/include to Header Search Paths —
// the C++ headers will break Xcode's Clang module scanner.
#include "../../../../Vendor/aftl/mtp/ptp/Device.h"
#include "../../../../Vendor/aftl/mtp/ptp/Session.h"
#include "../../../../Vendor/aftl/mtp/usb/BulkPipe.h"
#include "../../../../Vendor/aftl/mtp/ByteArray.h"
#include "../../../../Vendor/aftl/mtp/log.h"

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <functional>

// ---------------------------------------------------------------------------
// Internal session state
// ---------------------------------------------------------------------------
struct AFTLSession {
    mtp::usb::ContextPtr      usb_context;
    mtp::DevicePtr            device;
    mtp::SessionPtr           session;
    mtp::StorageId            storage_id;
    uint32_t                  root_object_id;   // typically 0 (Storage Root)

    // Path → ObjectId cache for fast lookups
    std::unordered_map<std::string, uint32_t> path_cache;
    std::mutex                                cache_mutex;

    // Canonical root path on device
    std::string root_path = "/storage/emulated/0";
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static char *dup_string(const std::string &s) {
    char *p = static_cast<char *>(std::malloc(s.size() + 1));
    if (p) {
        std::memcpy(p, s.c_str(), s.size() + 1);
    }
    return p;
}

static std::vector<std::string> split_path(const std::string &path) {
    std::vector<std::string> parts;
    std::string part;
    for (size_t i = 0; i < path.size(); ++i) {
        if (path[i] == '/') {
            if (!part.empty()) {
                parts.push_back(part);
                part.clear();
            }
        } else {
            part += path[i];
        }
    }
    if (!part.empty()) {
        parts.push_back(part);
    }
    return parts;
}

// ---------------------------------------------------------------------------
// Path resolution with cache
// ---------------------------------------------------------------------------

static uint32_t resolve_child(AFTLSession *s, uint32_t parent_id,
                              const std::string &child_name) {
    auto handles = s->session->GetObjectHandles(
        s->storage_id, mtp::ObjectFormat::Any, parent_id);

    for (auto id : handles.ObjectHandles) {
        auto info = s->session->GetObjectInfo(id);
        if (info.Filename == child_name) {
            return id;
        }
    }
    return 0; // not found
}

// ---------------------------------------------------------------------------
// Exported C functions
// ---------------------------------------------------------------------------

extern "C" {

AFTLSessionRef aftl_connect(void) {
    auto *s = new AFTLSession();

    try {
        // Create USB context and find first MTP device
        s->usb_context = mtp::usb::Context::Create();
        s->device = mtp::Device::FindFirst(s->usb_context);
        if (!s->device) {
            delete s;
            return nullptr;
        }

        // Open MTP session (session ID 1 is conventional)
        s->session = s->device->OpenSession(1);
        if (!s->session) {
            delete s;
            return nullptr;
        }

        // Enumerate storages and pick the first one
        auto storages = s->session->GetStorageIds();
        if (storages.StorageIds.empty()) {
            delete s;
            return nullptr;
        }
        s->storage_id = storages.StorageIds.front();
        s->root_object_id = 0; // MTP storage root

        // Cache root path
        {
            std::lock_guard<std::mutex> lock(s->cache_mutex);
            s->path_cache[s->root_path] = s->root_object_id;
            s->path_cache["/"] = s->root_object_id;
        }

        return static_cast<AFTLSessionRef>(s);

    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL connect failed: %s\n", e.what());
        delete s;
        return nullptr;
    }
}

void aftl_disconnect(AFTLSessionRef handle) {
    if (!handle) return;
    auto *s = static_cast<AFTLSession *>(handle);
    // Session and Device are ref-counted, releasing the pointer is enough
    s->session.reset();
    s->device.reset();
    s->usb_context.reset();
    delete s;
}

bool aftl_is_connected(AFTLSessionRef handle) {
    return handle != nullptr;
}

// ---------------------------------------------------------------------------
// Device info
// ---------------------------------------------------------------------------

AFTLDeviceInfo aftl_get_device_info(AFTLSessionRef handle) {
    AFTLDeviceInfo info = {};
    if (!handle) return info;
    auto *s = static_cast<AFTLSession *>(handle);

    try {
        auto dev_info = s->session->GetDeviceInfo();
        info.manufacturer = dup_string(dev_info.Manufacturer);
        info.model        = dup_string(dev_info.Model);
        info.serial       = dup_string(dev_info.SerialNumber);

        // Build storage description
        auto si = s->session->GetStorageInfo(s->storage_id);
        char buf[128];
        uint64_t total = si.MaxCapacity;
        uint64_t free_space = si.FreeSpaceInBytes;
        snprintf(buf, sizeof(buf), "%.1f GB, %.1f GB free",
                 total / 1073741824.0, free_space / 1073741824.0);
        info.storage_description = dup_string(buf);

    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL get_device_info failed: %s\n", e.what());
    }
    return info;
}

void aftl_free_device_info(AFTLDeviceInfo *info) {
    if (!info) return;
    std::free(info->manufacturer);   info->manufacturer = nullptr;
    std::free(info->model);          info->model = nullptr;
    std::free(info->serial);         info->serial = nullptr;
    std::free(info->storage_description); info->storage_description = nullptr;
}

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

int aftl_resolve_path(AFTLSessionRef handle, const char *path,
                      uint32_t *object_id) {
    if (!handle || !path || !object_id) return -1;
    auto *s = static_cast<AFTLSession *>(handle);
    std::string p(path);

    // Check cache
    {
        std::lock_guard<std::mutex> lock(s->cache_mutex);
        auto it = s->path_cache.find(p);
        if (it != s->path_cache.end()) {
            *object_id = it->second;
            return 0;
        }
    }

    // Walk the path components
    auto parts = split_path(p);
    uint32_t current = s->root_object_id;
    std::string accumulated = s->root_path;

    for (const auto &part : parts) {
        // Skip if this component matches the root path tail
        if (accumulated == s->root_path && part == split_path(s->root_path).back()) {
            continue;
        }

        // Check cache for accumulated path
        std::string next_path = accumulated + "/" + part;
        {
            std::lock_guard<std::mutex> lock(s->cache_mutex);
            auto it = s->path_cache.find(next_path);
            if (it != s->path_cache.end()) {
                current = it->second;
                accumulated = next_path;
                continue;
            }
        }

        // Resolve via MTP
        uint32_t child = resolve_child(s, current, part);
        if (child == 0) return -2; // path component not found

        current = child;
        accumulated = next_path;

        // Cache it
        {
            std::lock_guard<std::mutex> lock(s->cache_mutex);
            s->path_cache[accumulated] = current;
        }
    }

    *object_id = current;
    return 0;
}

uint32_t aftl_get_root_object_id(AFTLSessionRef handle) {
    if (!handle) return 0;
    return static_cast<AFTLSession *>(handle)->root_object_id;
}

// ---------------------------------------------------------------------------
// File listing
// ---------------------------------------------------------------------------

int aftl_list_files(AFTLSessionRef handle, const char *path,
                    AFTLFileList *out) {
    if (!handle || !path || !out) return -1;
    auto *s = static_cast<AFTLSession *>(handle);

    try {
        uint32_t parent_id = 0;
        if (aftl_resolve_path(handle, path, &parent_id) != 0) {
            return -2;
        }

        auto handles = s->session->GetObjectHandles(
            s->storage_id, mtp::ObjectFormat::Any, parent_id);

        std::vector<AFTLFileInfo> files;
        files.reserve(handles.ObjectHandles.size());

        for (auto id : handles.ObjectHandles) {
            auto info = s->session->GetObjectInfo(id);

            AFTLFileInfo fi = {};
            fi.object_id   = id;
            fi.name         = dup_string(info.Filename);
            fi.size         = info.ObjectCompressedSize;
            fi.is_directory = (info.ObjectFormat == mtp::ObjectFormat::Association);

            // Cache the full path for this object
            std::string child_path =
                std::string(path) + "/" + info.Filename;
            {
                std::lock_guard<std::mutex> lock(s->cache_mutex);
                s->path_cache[child_path] = id;
            }

            files.push_back(fi);
        }

        // Transfer ownership to caller
        out->count = static_cast<int>(files.size());
        if (out->count > 0) {
            out->items = static_cast<AFTLFileInfo *>(
                std::malloc(sizeof(AFTLFileInfo) * files.size()));
            std::memcpy(out->items, files.data(),
                        sizeof(AFTLFileInfo) * files.size());
        } else {
            out->items = nullptr;
        }
        return 0;

    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL list_files failed: %s\n", e.what());
        return -3;
    }
}

void aftl_free_file_list(AFTLFileList *list) {
    if (!list || !list->items) return;
    for (int i = 0; i < list->count; ++i) {
        std::free(list->items[i].name);
    }
    std::free(list->items);
    list->items = nullptr;
    list->count = 0;
}

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------

int aftl_download(AFTLSessionRef handle, uint32_t object_id,
                  const char *local_path,
                  void (*progress_cb)(double, void *),
                  void *userdata) {
    if (!handle || !local_path) return -1;
    auto *s = static_cast<AFTLSession *>(handle);

    try {
        auto info = s->session->GetObjectInfo(object_id);
        uint64_t total_size = info.ObjectCompressedSize;

        // Use GetPartialObject for chunked download with progress
        std::ofstream out(local_path, std::ios::binary);
        if (!out.is_open()) return -2;

        const uint64_t chunk_size = 256 * 1024; // 256 KB chunks
        uint64_t offset = 0;

        while (offset < total_size) {
            uint64_t to_read = std::min(chunk_size, total_size - offset);
            auto data = s->session->GetPartialObject(object_id, offset,
                                                     static_cast<uint32_t>(to_read));
            if (data.Size() == 0) break;

            out.write(reinterpret_cast<const char *>(data.Data()), data.Size());
            offset += data.Size();

            if (progress_cb && total_size > 0) {
                progress_cb(static_cast<double>(offset) / total_size, userdata);
            }
        }

        out.close();
        if (progress_cb) progress_cb(1.0, userdata);
        return 0;

    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL download failed: %s\n", e.what());
        return -3;
    }
}

// ---------------------------------------------------------------------------
// Upload
// ---------------------------------------------------------------------------

int aftl_upload(AFTLSessionRef handle, const char *local_path,
                uint32_t parent_object_id,
                void (*progress_cb)(double, void *),
                void *userdata,
                uint32_t *new_object_id) {
    if (!handle || !local_path) return -1;
    auto *s = static_cast<AFTLSession *>(handle);

    try {
        // Get local file info
        std::ifstream in(local_path, std::ios::binary | std::ios::ate);
        if (!in.is_open()) return -2;
        uint64_t file_size = in.tellg();
        in.seekg(0);

        std::string filename = local_path;
        auto pos = filename.rfind('/');
        if (pos != std::string::npos) filename = filename.substr(pos + 1);

        // Build ObjectInfo for the new file
        mtp::msg::ObjectInfo obj_info;
        obj_info.Filename      = filename;
        obj_info.ObjectFormat  = mtp::ObjectFormat::Undefined; // let device decide
        obj_info.StorageId     = s->storage_id;
        obj_info.ParentObject  = parent_object_id;

        // SendObjectInfo creates the metadata entry
        auto new_info = s->session->SendObjectInfo(obj_info, s->storage_id,
                                                    parent_object_id);
        uint32_t new_id = new_info.ObjectId;

        // Read file into memory (for SendObjectStream)
        // For large files we'd want streaming, but AFTL's SendObjectStream
        // takes an IObjectInputStream.  Use ByteArray for now.
        std::vector<uint8_t> buf(file_size);
        in.read(reinterpret_cast<char *>(buf.data()), file_size);
        in.close();

        mtp::ByteArray data(buf.data(), buf.size());
        auto stream = mtp::IObjectInputStream::Create(data);
        s->session->SendObject(stream);

        if (progress_cb) progress_cb(1.0, userdata);
        if (new_object_id) *new_object_id = new_id;
        return 0;

    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL upload failed: %s\n", e.what());
        return -3;
    }
}

// ---------------------------------------------------------------------------
// Delete & Mkdir
// ---------------------------------------------------------------------------

int aftl_delete(AFTLSessionRef handle, uint32_t object_id) {
    if (!handle) return -1;
    auto *s = static_cast<AFTLSession *>(handle);
    try {
        s->session->DeleteObject(object_id);
        // Remove from cache
        {
            std::lock_guard<std::mutex> lock(s->cache_mutex);
            for (auto it = s->path_cache.begin(); it != s->path_cache.end(); ) {
                if (it->second == object_id) it = s->path_cache.erase(it);
                else ++it;
            }
        }
        return 0;
    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL delete failed: %s\n", e.what());
        return -2;
    }
}

int aftl_mkdir(AFTLSessionRef handle, const char *name,
               uint32_t parent_object_id, uint32_t *new_dir_id) {
    if (!handle || !name) return -1;
    auto *s = static_cast<AFTLSession *>(handle);
    try {
        auto info = s->session->CreateDirectory(name, parent_object_id,
                                                 s->storage_id);
        if (new_dir_id) *new_dir_id = info.ObjectId;
        return 0;
    } catch (const std::exception &e) {
        fprintf(stderr, "AFTL mkdir failed: %s\n", e.what());
        return -2;
    }
}

} // extern "C"
