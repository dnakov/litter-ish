//
//  iOSFS.h
//  iSH
//
//  Created by Noah Peeters on 26.10.19.
//

#import <Foundation/Foundation.h>

extern const struct fs_ops iosfs;
extern const struct fs_ops iosfs_unsafe;

void iosfs_init(void);
void iosfs_clear_all_bookmarks(void); // for recovery

NSArray<NSDictionary<NSString *, NSString *> *> *iosfs_external_folder_mounts(void);
BOOL iosfs_add_external_folder_mount_url(NSURL *url, NSError **error);
void iosfs_remove_external_folder_mount(NSString *name);
