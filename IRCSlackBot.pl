#!/usr/bin/perl --
use utf8;
use strict;
use warnings;
use JSON;
use Carp;
use Data::Dump;
use Furl;
use Encode;
use Encode::Guess;
use Time::HiRes qw(time);
use JIS4IRC;

require POE::Wheel::Run;
require POE::Component::Client::DNS;
require POE::Component::IRC;
use POE qw(Component::IRC);
use AnyEvent;
use AnyEvent::SlackRTM;
use AnyEvent::HTTP;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

my $debug = 0;

our $TAG = '$$TAG$$';
sub console($;$$$$$$$$$$$$$$$$){
	printf STDERR @_;
	print STDERR "\n";
}


# 設定ファイルを読む
my $config_file = shift // 'config.pl';
my $config = do $config_file;
$@ and die "$config_file : $@\n";

my $URL_CHANNEL_LIST = "https://slack.com/api/channels.list";
my $URL_USER_LIST = "https://slack.com/api/users.list";
my $slack_bot_token = $config->{slack_bot_api_token};
my $slack_channel_id = find_channel_id( $config->{slack_channel_name} );
my $slack_bot_name = $config->{slack_bot_name};
console "Slack Channel: $slack_channel_id,$config->{slack_channel_name}";


# Slack チャンネル名からチャンネルIDを探す
sub find_channel_id{
	my($channel_name)=@_;
	my $channel_id;

	eval{
		my $furl = Furl->new( agent => "IRCSlackBot" );
    	my $res = $furl->get( "$URL_CHANNEL_LIST?token=$slack_bot_token");
    	die $res->status_line unless $res->is_success;
		my $json = decode_json($res->content);
		if( not $json->{ok} ){
			die "channel.list error=$json->{error}\n";
		}else{
		    for my $channel ( @{ $json->{channels} } ){
				if( "\#$channel->{name}" eq $channel_name ){
					$channel_id = $channel->{id};
					last;
				}
			}
			$channel_id or die "missing Slack channel '$channel_name'";
		}
	};
	$@ and die "$@\n";
	
	return $channel_id;
}

# Slack ユーザ名の一覧を更新
my $slack_user_map ={};
my $slack_user_map_update =0;
sub update_slack_cache {

	# 不必要ならキャッシュ更新を控える
	my $now = time;
	return if $now - $slack_user_map_update < 5*60;

	$slack_user_map_update = $now;

	console "get slack user list..";
	http_get "$URL_USER_LIST?token=$slack_bot_token", sub {
		my($data,$headers)=@_;
		console "parse slack user list..";
		eval{
			my $json = decode_json($data);
		    if( not $json->{ok} ){
				console "unable to get user list, Slack returned an error: $json->{error}"
			}else{
			    for my $member ( @{ $json->{members} } ){
					$slack_user_map->{ $member->{id} } = $member;
				}
				console "slack user list size=".scalar(%$slack_user_map);
			}
		};
		$@ and console $@;
	};
}

#########################################################################


my $slack_rtm;
my $keep_alive;

sub slack_start{

	update_slack_cache();

	$slack_rtm = AnyEvent::SlackRTM->new($slack_bot_token);

	$slack_rtm->on(
		'finish' => sub {
			print "Slack Connection finished.\n";
			undef $slack_rtm;
			undef $keep_alive;
		}
	);

	$slack_rtm->on(
		'hello' => sub {
			print "Slack Connection ready.\n";

			$keep_alive = AnyEvent->timer(
				interval => 60
				, cb => sub {
					# Pingを送るらしいがログに出てこない。いつ呼ばれるんだろう
					console "Slack Connection Ping.\n";
					$slack_rtm->ping;
					
					# ユーザ名キャッシュを定期的に更新する
					update_slack_cache();
				}
			);
		}
	);

	$slack_rtm->on(
		'message' => sub {
			my($rtm, $message) = @_;
			eval{
				# 発言者のIDと名前を調べる
				my $member;
				if( $message->{user_profile} ){
					$member = $slack_user_map->{ $message->{user} } = $message->{user_profile};
				}else{
					$member = $slack_user_map->{ $message->{user} };
				}
				my $from =  (not defined $member ) ? $message->{user} : $member->{name};
				
				# たまに起動直後に過去の自分の発言を拾ってしまう
				# 自分の発言はリレーしないようにする
				return if $from eq $slack_bot_name;

				# subtype によっては特殊な出力が必要
				if( $message->{subtype} and $message->{subtype} eq "channel_join" ){
					relay_to_irc( "${from} さんが参加しました");
				}elsif( $message->{subtype} and $message->{subtype} eq "channel_leave" ){
					relay_to_irc( "${from} さんが退出しました");
				}else{
					console Data::Dump::dump($message) if $message->{subtype};
					my $from =  (not defined $member ) ? $message->{user} : $member->{name};
					relay_to_irc( "<$from> $message->{text}");
				}
			};
			$@ and console $@;
		}
	);

	$slack_rtm->start;
}

# slackのチャンネルにメッセージを送る
sub relay_to_slack{
	my($msg)=@_;
	# $msg はUTF8フラグつきの文字列
	eval{
		$slack_rtm->send(
			{
				type => 'message'
				,channel => $slack_channel_id
				,text => $msg
			}
		);
	};
	$@ and warn $@;
}

###########################################################

my $relay_irc_bot ;
my $relay_irc_channel;

# $msg は UTF8フラグつきの文字列であること
sub relay_to_irc{
	my($msg)=@_;
	eval{
		if( $relay_irc_bot and $relay_irc_channel ){
			console "SlackToIRC: $relay_irc_channel $msg ";
			$relay_irc_bot->{irc}->yield( notice => $relay_irc_channel , $relay_irc_bot->{encode}($msg) );
		}
	};
	$@ and console $@;
}

############################################################

sub handle_message($$$$$$){
	my( $kernel,$heap,$bot,$from,$channel,$msg) = @_;

	if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*tateURL>exit\s*\z/ ){
		console "%s %s: exit required by (%s),said (%s)",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$from,$msg;
		$bot->{irc}->yield( part => $channel );
	}else{
		$from =~ s/!.*//;
		relay_to_slack("<$from> $msg");
	}
}

###################################################
# IRC接続の管理

POE::Session->create(
	inline_states => {
		_start	   => \&bot_start, # セッション開始
		bot_timer => \&bot_timer, # 定期的に実行
		
		irc_connected	 => \&on_connect, # 接続できた
		irc_disconnected => \&on_disconnect, # 接続終了
		connection_ping  => \&on_connection_ping,  # 再接続を行う
		# サーバ接続直後
		irc_001    => \&on_001,  # 自分のprefixを調べる
		irc_376    => \&on_motd, # end of MOTD
		irc_422    => \&on_motd, # no MOTD
		# チャンネルへの参加
		irc_join   => \&on_join,   # チャンネルに入った
		irc_kick   => \&on_kick,   # 蹴られた
		irc_invite => \&on_invite, # 呼ばれた
		# メッセージ処理
		irc_public => \&on_public,
		irc_msg => \&on_public,
		# 子プロセスのイベント
		child_stdout => \&child_stdout,
		child_stderr => \&child_stderr,
		child_error  => \&child_error,
		child_close  => \&child_close,
		child_signal => \&child_signal,
	},
);


sub fix_channel_name($$){
	my($channel,$short_safe_channel)=@_;
	# safe channel の長いprefix を除去する
	$short_safe_channel and $channel =~ s/^\!.{5}/!/;
	# 大文字小文字の統一
	$channel =~ tr/\[\]\\ABCDEFGHIJKLMNOPQRSTUVWXYZ/\{\}\|abcdefghijklmnopqrstuvwxyz/;
	#
	return $channel;
}


# セッション開始時に呼ばれる
sub bot_start {
	my $kernel	= $_[KERNEL];
	my $heap	= $_[HEAP];
	my $session = $_[SESSION];
	# IRCオブジェクトを登録して接続する
	console "register IRC component..";
	
	{
		my $bot = $config->{irc_server};
		
		if( not $bot->{encode} ){
			if($bot->{is_jis} ){
				$bot->{encode} = sub{ JIS4IRC::fromEUCJP( $eucjp->encode($_[0])); };
				$bot->{decode} = sub{ $eucjp->decode( JIS4IRC::toEUCJP(  $_[0])); };
			}else{
				$bot->{encode} = sub{ $utf8->encode($_[0]); };
				$bot->{decode} = sub{ $utf8->decode($_[0]); };
			}
		}

		$bot->{irc} = POE::Component::IRC->spawn();
		$bot->{irc}->{$TAG} = $bot;
		$bot->{irc}->yield( register => 'all' );
		# チャネル名を正規化しておく
		$bot->{JoinChannelFixed} = {
			map{ (fix_channel_name($_,0),1) }
			@{$bot->{JoinChannel}}
		};
	}
	{
		my $bot = $config->{irc_server};
		bot_connect( $bot,$bot->{irc} );
	}
	# タイマー開始
	$kernel->delay( bot_timer => 60 );
}

sub bot_timer{
	my $kernel	= $_[KERNEL];
	my $heap	= $_[HEAP];
	my $session = $_[SESSION];
	# 次回のタイマー
	$kernel->delay( bot_timer => 60 );
	# 接続開始
	{
		my $bot = $config->{irc_server};
		bot_connect( $bot );
	}
}

###############################
# 接続状態の管理

sub bot_connect($){
	my($bot)=@_;
	if( $bot->{irc}{connected} ){
		## console "%s: already connected. ",$bot->{Name};
	}else{
		console "%s: connecting..",$bot->{Name};
		$bot->{irc}->yield( connect => $bot->{ServerSpec} );
	}
}

sub on_connect {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: connected to %s. please wait authentication..",$bot->{Name},$_[ARG0];
	$_[KERNEL]->delay( connection_ping => 60, $bot);
}

sub on_disconnect {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: disconnected.",$bot->{Name};
}

sub on_connection_ping{
	my $bot = $_[ARG0];
	if( $bot->{irc}->connected() && $bot->{server_prefix} ){
		$bot->{irc}->yield( ping => $bot->{server_prefix} );
		$_[KERNEL]->delay( connection_ping => 60, $bot);
	}
	if( not $slack_rtm ){
		slack_start();
	}
}

###############################
# 接続直後の初期化

sub on_001 {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $line = $bot->{encode}($_[ARG1]);
	console "%s: 001 from=%s line=%s",$bot->{Name},$from,$line;
	# 自分のprefixを覚えておく
	$line =~ /(\S+\!\S+\@\S+)/ and $bot->{user_prefix} = $1;
	$bot->{server_prefix} = $from;
}

sub on_motd {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: end of MOTD.",$bot->{Name};
	for my $channel (keys %{ $bot->{JoinChannelFixed} } ){
		console "join to $channel";
		my $arg = $bot->{encode}( $channel );
		$bot->{irc}->yield( join => $arg );
	}
	for my $channel (keys %{ $bot->{CurrentChannel} } ){
		console "join to $channel";
		my $arg = $bot->{encode}( $channel );
		$bot->{irc}->yield( join => $arg );
	}
}

sub on_join {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $who =  $_[ARG0];
	my $channel =  fix_channel_name($bot->{decode}($_[ARG1]),1);

	if( $who ne $bot->{user_prefix} ){
		# 他人のjoin
		# auto-op check
		for my $re (@{ $bot->{AutoOpRegEx} }){
			if( $who =~ /$re/ ){
				$who =~ /^([^!]+)/;
				console "%s %s: +o to %s",$bot->{Name},$channel,$1;
				$bot->{irc}->yield( mode => $_[ARG1] , "+o",$1 );
				last;
			}
		}
		return;
	}else{
		console "%s %s: join %s",$bot->{Name},$channel,$who;
		$bot->{JoinChannelFixed}{$channel} or $bot->{CurrentChannel}{$channel}=1;
		
		$relay_irc_bot = $bot;
		$relay_irc_channel = $_[ARG1];

	}
}

sub lc_irc($){
	my($s)=@_;
	$s =~ tr/\[\]\\/\{\}\|/;
	return lc $s;
}

sub on_kick {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $channel =  fix_channel_name($bot->{decode}($_[ARG1] ),1);
	my $who =  $_[ARG2];
	my $msg = $bot->{decode}( $_[ARG3] );
	
	$bot->{user_prefix} =~ /^([^!]+)/;
	my $my_nick = $1;

	if( lc_irc($who) eq lc_irc($bot->{user_prefix})
	or	lc_irc($who) eq lc_irc($my_nick)
	){
		# 自分がkickされた
		console "%s %s: kick (%s) by (%s) %s",$bot->{Name},$channel,$who,$from,$msg;
		delete $bot->{CurrentChannel}{$channel};
	}else{
		# 他人がkickされた
	}
}

sub on_invite {
#	my $bot = $_[SENDER]->get_heap()->{$TAG};
#	my $who =  $_[ARG0];
#	my $channel = $_[ARG1];
#	console "%s: invited to %s by %s",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$who;
#	$bot->{irc}->yield( join => $channel );
}

sub on_public {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $channel = $_[ARG1];
	my $msg = $bot->{decode}($_[ARG2]);
	if(ref $channel ){
		$channel = shift @$channel;
	}
#	console "on_public %s %s",$bot->{decode}($channel),$msg;
	handle_message( $_[KERNEL],$_[HEAP],$bot,$from,$channel,$msg);
}


slack_start();

$poe_kernel->run();
exit 0;
