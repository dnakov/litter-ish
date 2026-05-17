//
//  MountsViewController.m
//  iSH
//

#import "MountsViewController.h"
#import "iOSFS.h"

@interface MountsViewController () <UIDocumentPickerDelegate>

@property NSArray<NSDictionary<NSString *, NSString *> *> *mounts;

@end

@implementation MountsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Mounts";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addMount:)];
    [self reloadMounts];
}

- (void)reloadMounts {
    self.mounts = iosfs_external_folder_mounts();
    [self.tableView reloadData];
}

- (void)addMount:(id)sender {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.folder" ]
                                                                                                    inMode:UIDocumentPickerModeOpen];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mounts.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Mount"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Mount"];
    }
    NSDictionary<NSString *, NSString *> *mount = self.mounts[indexPath.row];
    cell.textLabel.text = mount[@"name"];
    cell.detailTextLabel.text = mount[@"mountPoint"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;

    iosfs_remove_external_folder_mount(self.mounts[indexPath.row][@"name"]);
    [self reloadMounts];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"External folders are mounted under /mnt/<short name>.";
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0)
        return;

    NSError *error = nil;
    if (!iosfs_add_external_folder_mount_url(urls[0], &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mount Failed"
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self reloadMounts];
}

@end
