# perl-irc-slack-relay-bot
SlackとIRCのチャンネル間でメッセージをリレーするbot。Perlで書きました

# 依存関係
use JSON;
use Carp;
use Data::Dump;
use Furl;
use Encode;
use Time::HiRes qw(time);
use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::IRC::Connection;

# 使い方

事前に、SlackのWebサイトでbotを作成してアクセストークン、ボット名、参加させたいチャンネルをメモしておきます

設定サンプルをコピー
`cp config.pl.sample config.pl `

設定ファイルを他人が読めないようにする
`chmod 600 config.pl`

接続設定を編集します
`emacs config.pl`

スクリプトに実行権限を付与します
`chmod +x ./start IRCSlackBot.pl`

起動コマンドを実行します
`./start`

# 挙動のクセなど
- 複数の接続・チャンネルを扱う機能はありません。
- IRCの発言は最大15秒待機して、複数の発言を1メッセージにまとめてからSlackに送ります
- IRCのNOTICEメッセージをリレーするかどうかは config.plで選択可能です。
- Slackからのメッセージの取得にはWebSocketのRTM APIを使っています。一部のプロキシ下など、WebSocketが使えない環境では動作しません。
