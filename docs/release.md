# wfolder Pro 发布

源码构建默认开放专业工具。商业构建嵌入发行方的 Ed25519 公钥，首次打开专业工具开始本机 14 天试用。试用结束后，用户可导入一次性购买对应的离线许可证。发行方可以配置 HTTPS 购买入口。

## 准备许可证

把私钥保存在仓库外的访问受限路径。每个发行渠道应固定自己的密钥对，已签发的许可证只能由带相应公钥的构建验证。

```sh
xcrun swift Scripts/issue-pro-license.swift generate /path/to/private/wfolder-pro.key
xcrun swift Scripts/issue-pro-license.swift issue /path/to/private/wfolder-pro.key "许可证持有人" /path/to/recipient-license.json
```

生成命令输出的公钥用于下列构建。向收件人提供生成的 JSON，可在「文件工具 → 导入许可证…」离线激活。首次试销可以由发行方确认订单后手动签发。

## 生成公证发布包

在 macOS 上使用 27 或以上 SDK，通过 Keychain 安装 **Developer ID Application** 证书并为 `notarytool` 配置 Keychain profile。更新 `Scripts/Info.plist` 的版本号后运行以下命令。

```sh
export WFOLDER_PRO_PUBLIC_KEY='<发行公钥的 Base64>'
export WFOLDER_SIGNING_IDENTITY='Developer ID Application: Company Name (TEAMID)'
export WFOLDER_NOTARY_PROFILE='wfolder-notary'
export WFOLDER_PRO_CHECKOUT_URL='https://your-checkout.example/wfolder'
./Scripts/package-release.sh
```

脚本构建 Apple 芯片和 Intel 通用应用，签名、提交公证、附加票据并执行 Gatekeeper 检查。发布时上传 `dist/` 的版本 ZIP 和对应 SHA-256 到 GitHub Release。用户可以从「文件工具 → 查看版本更新…」打开发布页并手动下载。

`WFOLDER_PRO_CHECKOUT_URL` 可选。该构建只打开配置的购买页，支付、订单管理及退款由发行方处理。开发和团队授权可以继续使用源码构建进行试用。
