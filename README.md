# lilil (旧名 perl-irc-slack-relay-bot)
IRC, Slack, Matrix などのチャットサービス間で、botアカウントを使ってメッセージを相互にリレーします。

# 挙動のクセなど
- 複数の接続・チャンネルを扱えます
- IRCの発言は最大15秒待機して、複数の発言を1メッセージにまとめてからSlackに送ります
- IRCのNOTICEメッセージをリレーするかどうかは config.plで選択可能です。
- Slackからのメッセージの取得にはWebSocketのRTM APIを使っています。一部のプロキシ下など、WebSocketが使えない環境では動作しません。

# 依存関係

```
perl 5.26

$ perl -MModule::Version -e 'for(@ARGV){$v=Module::Version::get_version($_);print"$_ $v\n"}' AnyEvent AnyEvent::HTTP AnyEvent::WebSocket::Client Attribute::Constant Data::Dump HTML::Entities JSON::XS LWP::UserAgent URI::Escape

AnyEvent 7.14
AnyEvent::HTTP 2.23
AnyEvent::WebSocket::Client 0.53
Attribute::Constant 1.01
Data::Dump 1.23
HTML::Entities 3.69
JSON::XS 3.04
LWP::UserAgent 6.31
URI::Escape 3.31
```

### 使い方

事前にSlackのWebサイトでbotを作成してアクセストークン、ボット名、参加させたいチャンネルをメモしておきます。
事前にMatrixでbot用のアカウントを作成して以下略。

設定サンプルをコピー
`cp config.pl.sample config.pl `

設定ファイルを他人が読めないようにする
`chmod 600 config.pl`

接続設定を編集します
`emacs config.pl`

スクリプトに実行権限を付与します
`chmod +x ./start ./hup lilil.pl`

起動コマンドを実行します
`./start`
