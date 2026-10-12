# Commit convention / 提交规范

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for new commits. Existing history does not need rewriting.

新提交统一采用 Conventional Commits；无需重写已有历史。

```text
type(scope)!: concise description
```

- `type` is required: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, or `revert`.
- `scope` is optional. Use lowercase letters, digits, and hyphens for a specific area such as `movpkg`, `subtitles`, `ui`, or `release`.
- `!` marks a breaking change. Explain the impact and migration in the body, starting a footer with `BREAKING CHANGE:`.
- The first line must be at most 72 characters, start its description with non-whitespace, and have no trailing whitespace. English or Chinese descriptions are accepted. Put motivation and details after a blank line in the body.
- Keep one logical change per commit. Use an imperative, specific description; avoid generic subjects such as `fix bug` or `update code`.

类型必填；范围可选，使用小写字母、数字和连字符。`!` 表示破坏性变更，并在正文的 `BREAKING CHANGE:` 段说明影响及迁移方式。首行不超过 72 个字符，描述可用中文或英文；一个提交只包含一项逻辑变更。

Examples / 示例：

```text
feat(movpkg): add episode subtitle extraction
fix(subtitles): preserve WebVTT timestamp offsets
docs: clarify Apple TV movie link support
ci(release): pin macOS deployment target
feat(export)!: change bilingual SRT output format
```

Enable the versioned local hook once per clone:

```sh
git config core.hooksPath .githooks
```

每次克隆仓库后执行上述命令，即可在本地提交时校验。Pull request 的 CI 也会校验每个新增的非合并提交；无需安装额外依赖。检查单条消息可运行：

```sh
printf '%s\n' 'fix(subtitles): preserve WebVTT timestamp offsets' | ./script/check-commit-message.sh /dev/stdin
```
