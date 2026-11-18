# Fork 同步说明（个人维护分支）

本仓库是 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 的 fork。

| 远程 | 地址 | 用途 |
| --- | --- | --- |
| `origin` | `git@github.com:qdog2012/sub2api.git` | 自己的 fork，推送个人改动 |
| `upstream` | `https://github.com/Wei-Shaw/sub2api.git` | 上游原始仓库，**只读**，只用来 fetch |

| 分支 | 说明 |
| --- | --- |
| `main` | 上游镜像分支，**不提交任何个人改动**（当前停在旧提交，按需自行同步） |
| `my-main` | 个人主线分支。所有自有需求都提交到这里，上游更新合并进这里 |

---

## 日常开发

```bash
# 确认在个人分支上
git switch my-main

# ...改代码...
git add -A
git commit -m "feat: 我的需求"
git push
```

建议按主题再开子分支（`feat/xxx`、`fix/xxx`），改完合回 `my-main`，避免 `my-main` 上堆太多未完成的提交。

---

## 同步上游更新（核心流程）

### 1. 拉取上游最新代码

```bash
git fetch upstream --prune --tags
```

### 2. 查看上游新增了什么

```bash
# 只看提交标题
git log --oneline --no-merges my-main..upstream/main

# 看具体改动
git diff my-main...upstream/main --stat
```

### 3. 合入到个人分支

```bash
git switch my-main
git merge upstream/main
```

- 没冲突：直接进入下一步。
- 有冲突：见下方「冲突处理」。

> 本仓库已设置 `merge.ff = false`，合并会产生一个 merge commit，便于日后分辨「哪些是上游的、哪些是我自己的」。

### 4. 验证 + 推送

```bash
git push
```

如果冲突较多或本地环境可跑，建议先本地构建/跑测试再推送。

---

## 下游同步（可选：让 fork 的 main 也跟上上游）

`main` 是纯镜像分支，保持与上游一致即可，用快进合并：

```bash
git fetch upstream --prune
git switch main
git merge --ff-only upstream/main
git push origin main
```

> 注意：推送 `main` 会触发 fork 仓库的 GitHub Actions（`backend-ci`、`security-scan`），消耗你自己的 Actions 额度。不想跑就跳过这一步，或者只在本地 fast-forward 不推送。

---

## 冲突处理

冲突基本都出现在「上游改了、我也改了」的文件上。原则：**保留上游的功能改进 + 保留我的定制逻辑**。

```bash
git status                    # 看冲突文件
git diff --name-only --diff-filter=U
# 编辑冲突文件，处理 <<<<<<< ======= >>>>>>>
git add <已解决的文件>
git merge --continue          # 或 git commit
```

想放弃这次合并、重来：

```bash
git merge --abort
```

小技巧：冲突文件多时，可以让上游版本做基准，再把自己的定制点逐个补回去：

```bash
git checkout --theirs -- <file>   # 先取上游版本
# 然后手动重新加回自己的改动
```

（注意：merge 中 `--theirs` = `upstream/main`，`--ours` = 合并前的 `my-main`。）

### 降低冲突概率的实践

1. **个人改动尽量成块、集中**：新增文件优先，少改上游核心文件；必须改时把逻辑抽到独立文件/函数里，上游文件里只留一两行调用点。
2. **配置/开关化**：定制功能用配置项或 feature flag 包起来，减少与上游默认行为的直接冲撞。
3. **勤同步**：上游提交多、间隔越久冲突越重，建议每周或每个上游版本同步一次。
4. **每次同步单独一个 commit**，冲突解决记录清楚，出问题好回退。

---

## 回退与排错

```bash
# 看当前分支相对上游的状态（左=上游独有，右=我独有）
git rev-list --left-right --count upstream/main...my-main

# 撤销最后一次 merge（未推送时）
git reset --hard ORIG_HEAD

# 已推送但想撤销
git revert -m 1 <merge-commit-hash>
```

---

## 常用检查命令

```bash
git remote -v                              # 远程配置
git branch -vv                             # 分支与上游跟踪关系
git log --oneline --graph --all -20        # 近期分叉情况
git log my-main..upstream/main --oneline   # 上游还有哪些没合进来
```