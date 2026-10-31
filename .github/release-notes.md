<!-- 在这里写这一版的变化：一句话概要，然后是「新功能」「修复」「升级」。写好后发布这个草稿 -->

## 下载

- **MacBox-{{VERSION}}.dmg**：打开后把 MacBox 拖到 Applications（应用程序）
- **MacBox-{{VERSION}}.dmg.sha256**：校验文件，`shasum -a 256 -c MacBox-{{VERSION}}.dmg.sha256`

**系统要求**：Apple Silicon（M 系列芯片）的 Mac，macOS 26 或更新版本。

这个 dmg 由 GitHub Actions 从标签 `v{{VERSION}}` 构建，附带构建来源证明。装了 [GitHub CLI](https://cli.github.com) 的话，可以确认它确实出自这个仓库：

```bash
gh attestation verify MacBox-{{VERSION}}.dmg --repo PykeDLing/macbox
```

## 第一次打开

MacBox 没有经过 Apple 公证，第一次打开时 macOS 会提示 Apple 无法验证“MacBox”是否包含恶意软件。点「完成」，然后到 **系统设置 › 隐私与安全性**，在页面底部点 **仍要打开**，再输入密码确认。或者在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/MacBox.app
```

---

## English

<!-- English summary of the changes -->

**Upgrading**: quit MacBox and replace it in Applications; your boxes and their data are kept. MacBox isn’t notarized, so on first launch go to **System Settings › Privacy & Security**, click **Open Anyway** and confirm with your password (or run the `xattr` command above).

**Verifying**: the dmg is built by GitHub Actions from the `v{{VERSION}}` tag. With the GitHub CLI, `gh attestation verify MacBox-{{VERSION}}.dmg --repo PykeDLing/macbox` confirms it came from this repository.

**Requirements**: a Mac with Apple silicon and macOS 26 or later.
