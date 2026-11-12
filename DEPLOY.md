# AI 项目日报云端部署

这个目录本身就是一个独立仓库，不包含上级目录的其他项目。云端每天生成日报，电脑不运行后台服务；桌面快捷方式只在你点击时检查并打开当天网页。

## 运行结构

1. GitHub Actions 每天北京时间约 08:17 抓取候选、调用 DeepSeek、生成 Markdown、网页和 PDF；08:47 有备用触发。
2. 生成成功后，把 `data/`、当天的 Markdown 和 `site/` 提交回仓库。
3. GitHub Pages Actions 把 `site/` 目录发布为公开网页。
4. 桌面“今日 AI 日报”启动器先读取 `site/latest.json`：
   - 有当天日报：直接打开网页。
   - 当天还没生成：使用本机已保存的 GitHub 授权触发云端工作流，并等待网页发布。

本地不会开机自启、常驻后台或轮询云端。

`ai-digest-schedule.yml` 使用 `Asia/Shanghai` 时区，主触发为 08:17，备用触发为 08:47；它只负责通知主工作流运行。去重守卫会保证同一天只生成一次。GitHub 的定时任务只从默认分支读取，实际启动时间仍可能延迟。

## 需要的 GitHub 配置

### 1. 新建公开仓库

在 GitHub 创建一个空的公开仓库，例如 `ai-digest`，不要勾选自动生成 README。

在 `E:\codex工程\杂项\gihub news` 中初始化并推送。Codex 使用自带 Git，可以代为执行：

```powershell
git init -b main
git remote add origin https://github.com/OWNER/REPOSITORY.git
git add .
git commit -m "initial cloud digest pipeline"
git push -u origin main
```

把 `OWNER/REPOSITORY` 换成实际仓库名。不要从 `E:\codex工程\杂项` 初始化 Git，也不要把 `E:\codex\config.toml` 复制进来。

### 2. 添加 Secret

仓库 `Settings -> Secrets and variables -> Actions -> New repository secret`：

- `DEEPSEEK_API_KEY`：必须。只从现有本机配置中读取一次，保存到 GitHub Secrets。

可选 Repository variable：

- `DEEPSEEK_MODEL`：默认 `deepseek-flash`。
- `DEEPSEEK_BASE_URL`：默认 `https://api.deepseek.com`。

不要把 Key 写入任何仓库文件。

### 3. 允许 Actions 写仓库

打开 `Settings -> Actions -> General -> Workflow permissions`，选择：

- Read and write permissions

否则生成成功后的状态和网页无法提交，去重与延迟记账也会失效。

### 4. 开启 GitHub Pages

打开 `Settings -> Pages`：

- Source：`GitHub Actions`

部署完成后的公开网址是：

```text
https://OWNER.github.io/REPOSITORY
```

不要带结尾斜杠，也不要直接指向某个日期页面。

## 第一次验证

1. 进入仓库 `Actions -> AI project daily digest -> Run workflow`。
2. 如果当天已有日报，勾选 `force` 才会重新生成；第一次完整验证可以勾选。
3. 确认运行全部为绿色。
4. 确认仓库中新出现或更新了：
   - `data/candidates-YYYY-MM-DD.json`
   - `YYYY-MM-DD-ai-digest.md`
   - `site/YYYY-MM-DD.html`
   - `site/YYYY-MM-DD.pdf`
   - `site/latest.json`
5. 等待 GitHub Pages 发布，浏览器直接打开 `https://OWNER.github.io/REPOSITORY/YYYY-MM-DD.html`。
   PDF 是附加产物；如果日志显示 `pdf=failed`，网页日报仍会正常发布和打开。
6. 把 `ensure-today.ps1` 和 `desktop-text.json` 复制到：

```text
%LOCALAPPDATA%\AI-Digest\
```

再把 `今日 AI 日报.vbs` 复制到桌面。点击它不会启动常驻程序；只有发现当天日报缺失时，才会触发一次云端生成并等待结果。

7. 云端连续成功两三天后，暂停本机 `ai-08-00` 自动化，避免本地和云端各生成一份日报。

## 本地干跑

不调用 DeepSeek、不打开浏览器、不写日报：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\make-ai-digest.ps1 `
  -Date 2026-11-09 `
  -CandidatesPath .\data\candidates-2026-11-09.json `
  -PromptPath .\digest-prompt.md `
  -DryRun

```
