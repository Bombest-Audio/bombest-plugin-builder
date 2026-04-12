# Backup Directory

This directory stores backups from plugin cleanup operations.

## Structure

```
backups/
  rollbacks/              # /reset-to-ideation backups
    PluginName_YYYYMMDD_HHMMSS.tar.gz
  destroyed/              # /destroy backups
    PluginName_YYYYMMDD_HHMMSS.tar.gz
    PluginName_entry.md   # PLUGINS.md entry snapshot
```

## Backup Types

### rollbacks/ - Implementation Rollbacks

**Created by:** `/reset-to-ideation [PluginName]`

**Contains:**
- Source code (Source/ directory)
- Build configuration (CMakeLists.txt)
- Implementation docs (architecture.md, plan.md)
- Handoff state (.continue-here.md)

**Purpose:** Allows restoring implementation if rollback was mistake.

**Restoration:**
```bash
cd plugins/PluginName/
tar -xzf ../../backups/rollbacks/PluginName_TIMESTAMP.tar.gz --strip-components=1
```

---

### destroyed/ - Complete Plugin Backups

**Created by:** `/destroy [PluginName]`

**Contains:**
- Complete plugin directory (all source, mockups, contracts)
- PLUGINS.md entry (separate *_entry.md file)
- Everything that was removed

**Purpose:** Last resort recovery if plugin deletion was mistake.

**Restoration:**
```bash
cd plugins/
tar -xzf ../backups/destroyed/PluginName_TIMESTAMP.tar.gz
# Manually restore PLUGINS.md entry from PluginName_entry.md
```

---

## Retention Policy

**Default:** Backups never auto-deleted

**Manual cleanup:**
```bash
# Remove backups older than 30 days
find backups/ -name "*.tar.gz" -mtime +30 -delete

# Remove specific plugin's backups
rm backups/rollbacks/PluginName_*.tar.gz
rm backups/destroyed/PluginName_*.tar.gz
```

**Recommendation:** Keep destroyed/ backups longer than rollbacks/, since destruction is more severe.

---

## Disk Space

Backups can accumulate. Check size periodically:

```bash
du -sh backups/rollbacks/
du -sh backups/destroyed/
du -sh backups/
```

---

## Git Tracking

Backups are **not tracked in git** (.gitignore excludes *.tar.gz).

**Why:**
- Backups are local safety nets, not project artifacts
- Can be large (45+ MB per plugin)
- Personal to each developer's workflow

**If you need version-controlled backups:** Commit before running cleanup commands.
