# perl-irc-slack-relay-bot
SlackとIRCのチャンネル間でメッセージをリレーするbot。Perlで書きました

依存関係
use JSON;
use Carp;
use Data::Dump;
use Furl;
use Encode;
use Time::HiRes qw(time);
use AnyEvent;
use AnyEvent::IRC::Connection;
use AnyEvent::SlackRTM;
use AnyEvent::HTTP;

使い方

事前に、SlackのWebサイトでbotを作成してアクセストークン、ボット名、参加させたいチャンネルをメモしておきます

# 設定サンプルをコピー
cp config.pl.sample config.pl 
# 設定ファイルを他人が読めないようにする
chmod 600 config.pl
# 接続設定を編集します
emacs config.pl

./start コマンドを実行します

