# 上游跟随同步（带删除保护）

本仓库 fork 自 [Healer-sys/Home](https://github.com/Healer-sys/Home)，并通过 GitHub Actions 自动跟随上游更新。

**与普通 fork 的区别：上游删掉的东西，这里不会跟着消失。**

## 它做什么

| 上游的操作 | 本仓库的反应 |
|---|---|
| 修改文件内容 | ✅ 跟随更新 |
| 新增文件 | ✅ 跟随新增 |
| **删除文件** | ⚠️ **自动恢复，删除不生效** |
| **把文件清空** | ⚠️ **自动恢复原内容** |
| 内容与本仓库冲突 | 取上游内容（删除仍不生效） |

## 三层备份

1. **历史记录** — 永不 force push、永不改写历史。任何旧版本都能从 commit 历史里找回：
   ```sh
   git log --oneline --all          # 找某个时间点
   git show <commit>:iptv/gx.m3u    # 直接取那时的文件内容
   ```

2. **每日快照标签** — 每天第一次同步前打一个 `snap-YYYYMMDD` 标签，指向当天同步前的状态：
   ```sh
   git tag -l                      # 列出所有快照
   git show snap-20261106:iptv/gx.m3u
   ```
   恢复整个仓库到某天：`git checkout snap-20261106 -- .`

3. **内容快照** — 每次同步前打包成 tar.gz，上传为 Actions artifact，保留 90 天。
   下载位置：Actions → 任意一次运行 → Artifacts → `backups-*`

## 同步节奏

- 每 4 小时检查一次（上游约每天 UTC 22:08 提交）
- 上游没更新时直接退出，不产生提交
- 可随时手动触发：**Actions** → `Sync upstream (protect deletions)` → **Run workflow**

## 文件说明

| 路径 | 作用 |
|---|---|
| `scripts/sync.sh` | 同步脚本，本地也能跑 |
| `.github/workflows/sync-upstream.yml` | 云端定时任务 |
| `SYNC_LOG.md` | 同步记录，每次实际同步后追加一行 |

## 本地手动同步

```sh
git clone https://github.com/cumberjie/Home.git
cd Home
git remote add upstream https://github.com/Healer-sys/Home.git
sh scripts/sync.sh
```

调试用：

```sh
DRY_RUN=1 sh scripts/sync.sh      # 只看上游改了什么，不动文件
SKIP_PUSH=1 sh scripts/sync.sh    # 本地合并但不推送
```

## 已知边界

- 只保护**文件级**的删除和清空。如果上游把 `A` 和 `B` 两个文件合并成一个 `C`，属于正常重构，不做恢复。
- 若上游连续 60 天无活动，GitHub 会自动停用定时任务（public 仓库的官方限制）。重新启用：Actions 页面点 **Enable workflow**。
- 上游若强制改写历史，本仓库按普通 merge 处理，不会丢本地已有的文件。
