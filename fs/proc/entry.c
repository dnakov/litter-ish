#include <sys/stat.h>
#include <stdint.h>
#include <string.h>
#include "fs/stat.h"
#include "fs/proc.h"
#include "kernel/task.h"

mode_t_ proc_entry_mode(struct proc_entry *entry) {
    mode_t_ mode = entry->meta->mode;
    if ((mode & S_IFMT) == 0)
        mode |= S_IFREG;
    if ((mode & 0777) == 0) {
        if (S_ISREG(mode))
            mode |= 0444;
        else if (S_ISDIR(mode))
            mode |= 0555;
        else if (S_ISLNK(mode))
            mode |= 0777;
    }
    return mode;
}

int proc_entry_stat(struct proc_entry *entry, struct statbuf *stat) {
    memset(stat, 0, sizeof(*stat));
    stat->mode = proc_entry_mode(entry);

    lock(&pids_lock);
    struct task *task = pid_get_task(entry->pid);

    if (task != NULL) {
        stat->uid = task->uid;
        stat->gid = task->gid;
    } // else the memset above will have initialized memory to zero, which is the root uid/gid

    unlock(&pids_lock);

    stat->inode = proc_entry_inode(entry);
    return 0;
}

qword_t proc_entry_inode(struct proc_entry *entry) {
    // Procfs entries need globally unique, stable-enough inode values so tools
    // like du don't mistake unrelated proc directories for cycles. FNV-1a over
    // (parent meta pointer, this meta pointer, name, pid, fd).
    uint64_t hash = 1469598103934665603ULL;
#define FNV_MIX_BYTE(v) do { hash ^= (uint8_t) (v); hash *= 1099511628211ULL; } while (0)
#define FNV_MIX_VALUE(v) do { \
    uint64_t value__ = (uint64_t) (uintptr_t) (v); \
    for (size_t i__ = 0; i__ < sizeof(value__); i__++) \
        FNV_MIX_BYTE(value__ >> (i__ * 8)); \
} while (0)

    FNV_MIX_VALUE(entry->meta->parent);
    FNV_MIX_VALUE(entry->meta);
    if (entry->meta->getname || entry->meta->name != NULL) {
        char name[MAX_NAME + 1];
        proc_entry_getname(entry, name);
        for (size_t i = 0; name[i] != '\0'; i++)
            FNV_MIX_BYTE(name[i]);
    }
    FNV_MIX_VALUE(entry->pid);
    FNV_MIX_VALUE(entry->fd);

    if (hash == 0)
        hash = 1;
    return hash;
#undef FNV_MIX_VALUE
#undef FNV_MIX_BYTE
}

void proc_entry_getname(struct proc_entry *entry, char *buf) {
    if (entry->meta->getname)
        entry->meta->getname(entry, buf);
    else if (entry->meta->name)
        strcpy(buf, entry->meta->name);
    else
        assert(!"missing name in proc entry");
}

bool proc_dir_read(struct proc_entry *entry, unsigned long *index, struct proc_entry *next_entry) {
    if (entry->meta->readdir)
        return entry->meta->readdir(entry, index, next_entry);

    if (entry->meta->children) {
        if (*index >= entry->meta->children->count)
            return false;
        next_entry->meta = &entry->meta->children->entries[*index];
        next_entry->pid = entry->pid;
        (*index)++;
        return true;
    }
    assert(!"read from invalid proc directory");
}

void free_string_array(char **array) {
    for (int i = 0; array[i] != NULL; i++)
        free(array[i]);
    free(array);
}

void proc_entry_cleanup(struct proc_entry *entry) {
    if (entry->name != NULL)
        free(entry->name);
    if (entry->child_names != NULL)
        free_string_array(entry->child_names);
    *entry = (struct proc_entry) {0};
}
