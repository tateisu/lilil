#!/usr/bin/perl --
use utf8;
use strict;
use warnings;

use JSON;
use Carp;
use Data::Dump;
use Furl;
use Encode;
use Time::HiRes qw(time);

use AnyEvent;
use AnyEvent::IRC::Connection;
use AnyEvent::HTTP;

use JIS4IRC;
use SlackBot;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

my $debug = 0;

sub console($;$$$$$$$$$$$$$$$$){
	my @lt = localtime;
	$lt[5]+=1900;
	$lt[4]+=1;
	printf STDERR "%d:%02d:%02d_%d:%02d:%02d ",reverse @lt[0..5];
	printf STDERR @_;
	print STDERR "\n";
}

sub dnl($){
	return defined $_[0] and length $_[0];
}

# 設定ファイルを読む
my $config_file = shift // 'config.pl';
my $config = do $config_file;
$@ and die "$config_file : $@\n";

#########################################################################
# handling SlackBot.pm

my $slack_bot;
my $slack_last_connection_start = 0; # 最後に接続を開始した時刻

my $slack_bot_id = undef; 
my $slack_bot_name = undef; 
my $slack_channel_id = undef;

my $slack_user_map ={};
my $slack_user_map_update =0; # 最後にuser.listを更新開始/完了した時刻

sub slack_user_update;

sub slack_status{
	return $slack_bot ? $slack_bot->status : "not connected";
}

sub slack_start{

	if( $slack_bot ){

		# 既に接続していてpingも途切れていないなら何もしない
		return if not $slack_bot->is_ping_timeout;

		# ping応答が途切れているようなので、今の接続は閉じる
		console "Slack: ping timeout.";
		$slack_bot->dispose;
		undef $slack_bot;

		# fall thru. そのまま作り直す
	}

	# 前回接続開始してから60秒以内は何もしない
	my $now = time;
	my $remain = $slack_last_connection_start + 60 -$now;
	$remain > 0 and return console "Slack: waiting %d seconds to restart connection.",$remain;
	$slack_last_connection_start = $now;

	console "Slack: connection start..";

	$slack_bot = SlackBot->new(
		token => $config->{slack_bot_api_token},
		ping_interval => ($config->{slack_ping_interval}//60),
		user_agent => 'tateisu/perl-irc-slack-relay-bot',
	);

	$slack_bot->on(

		$SlackBot::EVENT_CATCH_UP => sub {
			my($rtm, $event_type, @args) = @_;
			console "Slack: catch up event. $event_type %s",Data::Dump::dump(\@args);
		},

		$SlackBot::EVENT_RTM_CONNECTION_FINISHED => sub {
			console "Slack: connection finished.";
			$slack_bot->dispose;
			undef $slack_bot;
		},

		$SlackBot::EVENT_ERROR => sub {
			my($sb,$event_type,$error)=@_;
			console "Slack: error. $error";
			$slack_bot->dispose;
			undef $slack_bot;
		},

		$SlackBot::EVENT_SELF => sub {
			my($rtm, $event_type, $user) = @_;
			$slack_bot_id = $user->{id} if $user->{id};
			slack_user_update( $user );
		},

		$SlackBot::EVENT_CHANNELS => sub {
			my($rtm, $event_type, $data) = @_;
		    for my $channel ( @$data ){
				if( "\#$channel->{name}" eq $config->{slack_channel_name} ){
					$slack_channel_id = $channel->{id};
					console "Slack: channel: $channel->{id},\#$channel->{name}";
					last;
				}
			}
			$slack_channel_id or console "Slack: missing channel data for '$config->{slack_channel_name}'";
		},

		$SlackBot::EVENT_USERS => sub {
			my($rtm, $event_type, $data) = @_;

		    for my $user ( @$data ){
				slack_user_update( $user );
			}

			console "Slack: user list: size=".scalar(%$slack_user_map);
			$slack_user_map_update = time;
		},

		user_change => sub {
			my($rtm, $event_type, $data) = @_;

			my $user = $data->{user};
			console "Slack: user_change: $user->{id},$user->{name}";
			slack_user_update( $user );
		},

		$SlackBot::EVENT_TEAM => sub {} ,
		$SlackBot::EVENT_GROUPS => sub {} ,
		$SlackBot::EVENT_MPIMS => sub {} ,
		$SlackBot::EVENT_IMS => sub {} ,
		$SlackBot::EVENT_BOTS => sub {} ,

		#送信した発言のtsが確定した。発言をまとめるのに使えそうだが…
		$SlackBot::EVENT_REPLY_TO => sub {},

		hello => sub {
			console "Slack: connection ready.";
		},

		# The reconnect_url event is currently unsupported and experimental.
		reconnect_url => sub {},

		# このボットはユーザのアクティブ状態に興味がない
		presence_change => sub {},

		# このボットはユーザの入力中状態に興味がない
		user_typing => sub {},

		# pingへの応答
		pong => sub {},


		message => sub {
			my($rtm, $event_type, $message) = @_;
			eval{
				$message->{subtype}='' if not defined $message->{subtype};
				if( $message->{subtype} eq 'message_changed'){
					my $old_channel = $message->{channel};
					$message = $message->{message};
					$message->{channel} = $old_channel if not $message->{channel};
					$message->{subtype}='' if not defined $message->{subtype};
				}

				if( not $message->{user} ){
					console "Slack: missing user? %s",Data::Dump::dump($message);
					$message->{user}='?';
				}

				# たまに起動直後に過去の自分の発言を拾ってしまう
				# 自分の発言はリレーしないようにする
				return if defined $slack_bot_id and $slack_bot_id eq $message->{user};

				# 発言者のIDと名前を調べる
				my $member;
				if( $message->{user_profile} ){
					$member = $slack_user_map->{ $message->{user} } = $message->{user_profile};
				}else{
					$member = $slack_user_map->{ $message->{user} };
				}
				my $from =  (not defined $member ) ? $message->{user} : $member->{name};

				# メッセージ本文
				my $msg = $message->{text};
				if( defined $message->{message} and not defined $msg ){
					$msg = $message->{message}{text};
				}

				#warn "$message->{subtype},$slack_bot_name,$msg";
				
				# pingコマンド
				if( not $message->{subtype}
				and $slack_bot_name
				and $msg =~ /\A\s*$slack_bot_name&gt;ping\s*\z/i
				){
					$rtm->send({
						type => 'message'
						,channel => $message->{channel}
						,text => SlackBot::encode_entity( sprintf "%s>pong. irc[%s],slack[%s]",$from,irc_status(),slack_status() )
					});
					return;
				}

				# メッセージの宛先が定義されていて、しかし目的のチャンネルでないなら無視する
				if( defined $message->{channel} 
				and defined $slack_channel_id
				and $message->{channel} ne $slack_channel_id 
				){
					console "Slack: message destination not matcn. %s",Data::Dump::dump($message);
					return;
				}

				# subtype によっては特殊な出力が必要
				if( $message->{subtype} eq "channel_join" ){
					relay_to_irc( "${from} さんが参加しました");
				}elsif( $message->{subtype} eq "channel_leave" ){
					relay_to_irc( "${from} さんが退出しました");
				}else{
					console "Slack: missing subtype? %s",Data::Dump::dump($message) if $message->{subtype};

					if( dnl $msg ){
						my @lines = split /[\x0d\x0a]+/,SlackBot::decode_message($msg);
						for my $line (@lines){
							next if not dnl $line;
							relay_to_irc( "<$from> $line");
						}
					}
				}
			};
			$@ and console "Slack: message handling failed. $@";
		}
	);

	$slack_bot->start;
}

my @cue;
my $cue_oldest_time;

# slackのチャンネルにメッセージを送る
sub relay_to_slack{
	my($msg)=@_;
	# $msg はUTF8フラグつきの文字列
	eval{
		$cue_oldest_time = time if not @cue;
		push @cue,SlackBot::encode_entity($msg);
	}
}

sub flush_cue{

	return if not $slack_bot or not $slack_bot->is_ready ;

	return if not @cue or not $slack_channel_id;

	my $delta = time - $cue_oldest_time;
	return if $delta < 15;

	my $msg = join "\n",@cue;
	@cue = ();

	eval{
		$slack_bot->send(
			{
				type => 'message'
				,channel => $slack_channel_id
				,text => $msg
			#	,mrkdwn => JSON::false
			}
		);
	};
	$@ and warn $@;
}

sub update_user_list {

	# SlackBotが準備できていないなら何もしない
	return if not $slack_bot or not $slack_bot->is_ready;

	# 前回更新してから一定時間が経過するまで何もしない
	my $now = time;
	return if $now - $slack_user_map_update < $config->{slack_user_list_interval};
	$slack_user_map_update = $now;

	# 更新を開始(非同期API)
	console "get slack user list..";
	$slack_bot->get_user_list(sub{
		my $error = shift;
		console "Slack: user list update failed: $error";
	});
}

sub slack_user_update{
	my($user)=@_;

	# ignore incomplete user information
	return if not $user->{id};
	
	my $user_old = $slack_user_map->{ $user->{id} };

	$slack_user_map->{ $user->{id} } = $user;

	if( $slack_bot_id and $slack_bot_id eq $user->{id} ){
		$slack_bot_name = $user->{name} if $user->{name};
		console "Slack: me: id=$user->{id},name=$user->{name}";
	}
}


###########################################################
# IRC接続の管理

sub lc_irc($){
	my($s)=@_;
	$s =~ tr/\[\]\\/\{\}\|/;
	return lc $s;
}

sub fix_channel_name($$){
	my($channel,$short_safe_channel)=@_;
	# safe channel の長いprefix を除去する
	$short_safe_channel and $channel =~ s/^\!.{5}/!/;
	# 大文字小文字の統一
	$channel =~ tr/\[\]\\ABCDEFGHIJKLMNOPQRSTUVWXYZ/\{\}\|abcdefghijklmnopqrstuvwxyz/;
	#
	return $channel;
}

my $relay_irc_bot ;
my $relay_irc_channel;

my $irc_ping_interval = $config->{irc_server}{ping_interval} || 60;
$irc_ping_interval = 10 if $irc_ping_interval < 10;

my $irc_last_recv = time;

sub on_motd;
sub on_message;

# 一回だけの初期化
{
	console "register IRC bot...";

	my $bot = $config->{irc_server};

	if($bot->{is_jis} ){
		$bot->{encode} = sub{ JIS4IRC::fromEUCJP( $eucjp->encode($_[0])); };
		$bot->{decode} = sub{ $eucjp->decode( JIS4IRC::toEUCJP(  $_[0])); };
	}else{
		$bot->{encode} = sub{ $utf8->encode($_[0]); };
		$bot->{decode} = sub{ $utf8->decode($_[0]); };
	}

	$bot->{last_connection_start} = 0;
	$bot->{last_ping_sent} =0;

	# チャネル名を正規化しておく
	$bot->{JoinChannelFixed} = {
		map{ (fix_channel_name($_,0),1) }
		@{$bot->{JoinChannel}}
	};

	my $con = $bot->{irc} = new AnyEvent::IRC::Connection;
	$con->heap->{bot} = $bot;
	$con->reg_cb (

		#接続終了
		disconnect => sub {
			my ($con,$reason) = @_;
			$irc_last_recv = time;
			console "%s: disconnected. reason=$reason";
		},

		# 接続できた
		connect=> sub{
			my ($con,$error) = @_;
			$irc_last_recv = time;
			my $bot = $con->heap->{bot};
			if( $error ){
				console "%s: connection failed. error=$error",$bot->{Name};
			}else{
				console "%s: connected to %s:%s. please wait authentication..",$bot->{Name},$con->{host},$con->{port};
				$con->send_msg (NICK => $bot->{ServerSpec}{Nick});
				$con->send_msg (USER => $bot->{ServerSpec}{Username}, '*', '0',$bot->{encode}($bot->{ServerSpec}{Ircname}));
			}
		},

		'irc_*' => sub {
			my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			$irc_last_recv = time;
		},

		# 認証完了
		irc_001 => sub {
			my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			my $bot = $con->heap->{bot};
			#
			my $from = $args->{prefix}; # サーバ名
			my $line = $bot->{decode}( $args->{params}[-1]);
			console "%s: 001 from=%s line=%s",$bot->{Name},$from,$line;
			## console "$args->{prefix} says I'm in the IRC: $args->{params}->[-1]!";
			
			# 自分のprefixを覚えておく
			$bot->{server_prefix} = $from;
			$line =~ /(\S+\!\S+\@\S+)/ and $bot->{user_prefix} = $1;
		},

		# MOTD終了
		irc_376 => \&on_motd, # end of MOTD
		irc_422 => \&on_motd, # no MOTD

		irc_join => sub{
			my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			my $bot = $con->heap->{bot};
			#
			my $from = $args->{prefix}; # joinした人
			my $channel_raw = $args->{params}[0];
			my $channel = fix_channel_name($bot->{decode}($channel_raw),1);
			
			if( $from ne $bot->{user_prefix} ){
				# 他人のjoin
				# auto-op check
				for my $re (@{ $bot->{AutoOpRegEx} }){
					if( $from =~ /$re/ ){
						$from =~ /^([^!]+)/;
						console "%s %s: +o to %s",$bot->{Name},$channel,$1;
						$bot->send_msg( MODE => $channel_raw , "+o",$1 );
						last;
					}
				}
			}else{
				console "%s %s: join %s",$bot->{Name},$channel,$from;
				$bot->{JoinChannelFixed}{$channel} or $bot->{CurrentChannel}{$channel}=1;

				$relay_irc_bot = $bot;
				$relay_irc_channel = $channel_raw;
			}
		},
		
		irc_kick => sub{
			my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			my $bot = $con->heap->{bot};
			#
			my $from = $args->{prefix}; # joinした人
			
			my $line = $bot->{encode}( $args->{params}[0]);
			my $channel_raw = $args->{params}[0];
			my $channel = fix_channel_name($bot->{decode}($channel_raw),1);
			my $who = $args->{params}[1];
			my $msg = $bot->{decode}( $args->{params}[-1] );

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
		},
		

		irc_invite => sub{
			my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			my $bot = $con->heap->{bot};

			my $from = $args->{prefix}; # inviteした人
			my $channel_raw = $args->{params}[0];
			my $channel = fix_channel_name($bot->{decode}($channel_raw),1);
			
			console "%s: invited to %s by %s",$bot->{Name},$channel,$from;
			## $con->send_msg( JOIN => $channel_raw );
		},

		# メッセージ処理
		irc_privmsg => \&on_message,
		irc_notice => \&on_message,
	);
}

sub on_motd {
	my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
	my $bot = $con->heap->{bot};
	#
	console "%s: end of MOTD.",$bot->{Name};
	for my $channel (keys %{ $bot->{JoinChannelFixed} } ){
		console "join to $channel";
		$con->send_msg( JOIN => $bot->{encode}( $channel ) );
	}
	for my $channel (keys %{ $bot->{CurrentChannel} } ){
		console "join to $channel";
		$con->send_msg( JOIN => $bot->{encode}( $channel ) );
	}
}

sub on_message {
	my($con,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
	my $bot = $con->heap->{bot};

	my $from = $args->{prefix};
	my $command = $args->{command};

	my $channel_raw = $args->{params}[0];
	if(ref $channel_raw ){
		$channel_raw = shift @$channel_raw;
	}
	my $channel = fix_channel_name($bot->{decode}($channel_raw),1);

	my $msg = $bot->{decode}( $args->{params}[-1]);

	console "%s %s %s %s",$command,$from,$channel,$msg;

	##############################

	$bot->{user_prefix} =~ /^([^!]+)/;
	my $my_nick = $1;

	$from =~ /^([^!]+)/;
	my $from_nick = $1;

	# pingコマンド
	if( $my_nick and $msg =~ /\A\s*$my_nick>ping\s*\z/i ){
		$relay_irc_bot->{irc}->send_msg( NOTICE => $channel_raw ,$relay_irc_bot->{encode}( sprintf "%s>pong. irc[%s],slack[%s]",$from_nick,irc_status(),slack_status() ) );
		return;
	}
	
	##################################

	if( not grep {$_ eq $channel} keys %{ $bot->{JoinChannelFixed} } ){
		console "指定チャンネル宛てではないので無視します";
		return;
	}

	my $is_notice = ($command =~ /notice/i);
	if( $is_notice and $config->{slack_dont_relay_notice} ){
		console "NOTICEをリレーしない設定なので無視します";
		return;
	}

	my $is_action = 0;
	if( $msg =~ s/\A\x01ACTION\s+(.+)\x01\z/$1/ ){
		$is_action = 1;
	}


	if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>exit\s*\z/ ){
		console "%s %s: exit required by (%s),said (%s)",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$from,$msg;
		$con->send_msg( PART => $channel_raw );
	}else{
		$from =~ s/!.*//;
		if( $is_action ){
			if( $is_notice ){
				relay_to_slack("(action) [$from] $msg");
			}else{
				relay_to_slack("(action) <$from> $msg");
			}
		}else{
			if( $is_notice ){
				relay_to_slack("[$from] $msg");
			}else{
				relay_to_slack("<$from> $msg");
			}
		}
	}
}

sub irc_status{
	my $bot = $config->{irc_server};
	return "not connected" if not $bot->{irc}->is_connected;
	return "not authorized" if not $bot->{server_prefix};
	my @lt = localtime;
	return sprintf("connected. last_rx=%d:%02d:%02d",reverse @lt[0..2]);
}

sub irc_start($){
	my($bot)=@_;

	my $now = time;
	if( $bot->{irc}->is_connected ){
		my $delta = $now - $irc_last_recv;
		if( $delta > $irc_ping_interval * 3 ){
			console "%s: ping timeout.",$bot->{Name};
			$bot->{irc}->disconnect;
			$irc_last_recv = time;
		}else{
			# 既に接続しているし、pingも途切れていない
			return;
		}
	}
	
	# 前回接続開始して一定時間以内は何もしない
	my $remain = $bot->{last_connection_start} + 60 -$now;
	$remain > 0 and return console "%s: waiting %d seconds to restart connection.",$bot->{Name},$remain;
	$bot->{last_connection_start} = $now;

	undef $bot->{server_prefix};
	$bot->{irc}->connect( $bot->{ServerSpec}{Server},$bot->{ServerSpec}{Port});
	console "%s: connection start. %s:%s",$bot->{Name}, $bot->{ServerSpec}{Server},$bot->{ServerSpec}{Port};
}

sub irc_ping($){
	my($bot)=@_;

	if( $bot->{irc}->is_connected && $bot->{server_prefix} ){
		my $now = time;
		if( $now - $bot->{last_ping_sent} >= $irc_ping_interval ){
			$bot->{last_ping_sent} = $now;
			console "%s: sending ping.",$bot->{Name};
			$bot->{irc}->send_msg( PING =>  $bot->{server_prefix} );
		}
	}
}

my @duplicate_check;

# $msg は UTF8フラグつきの文字列であること
sub relay_to_irc{
	my($msg)=@_;
	eval{
		if( $relay_irc_bot and $relay_irc_channel ){
			# 最近の発言と重複する内容は送らない
			if( grep {$_ eq $msg } @duplicate_check ){
				console "SlackToIRC: omit duplicate message %s",$msg;
				return;
			}
			push @duplicate_check,$msg;
			shift @duplicate_check if @duplicate_check > 10;

			#
			console "SlackToIRC: %s %s",$relay_irc_channel,$msg;
			$relay_irc_bot->{irc}->send_msg( NOTICE => $relay_irc_channel ,$relay_irc_bot->{encode}($msg) );
		}
	};
	$@ and console "SlackToIRC: $@";
}

################################################################################
# タイマー

my $timer = AnyEvent->timer(
	interval => 1 , cb => sub {
		{
			my $bot = $config->{irc_server};

			# IRC接続のリトライ
			irc_start( $bot );

			# 既に接続しているなら一定時間でPINGを送る
			irc_ping($bot);
		}

		# Slack接続のリトライ
		slack_start();

		# ユーザ名キャッシュを定期的に更新する
		update_user_list();

		# Slackに発言を投げるキューの消化
		flush_cue();
	}
);

###############################

my $c = AnyEvent->condvar;
$c->wait;
exit 0;
