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

our $TAG = '$$TAG$$';
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

my $irc_ping_interval = $config->{irc_server}{ping_interval} || 60;
$irc_ping_interval = 10 if $irc_ping_interval < 10;

my $URL_CHANNEL_LIST = "https://slack.com/api/channels.list";
my $URL_USER_LIST = "https://slack.com/api/users.list";
my $slack_bot_token = $config->{slack_bot_api_token};
my $slack_channel_id = find_channel_id( $config->{slack_channel_name} );
my $slack_bot_name = $config->{slack_bot_name};
my $slack_dont_relay_notice= $config->{slack_dont_relay_notice};
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
my $slack_user_map_interval = $config->{slack_user_list_interval};

sub update_slack_cache {

	# 不必要ならキャッシュ更新を控える
	my $now = time;
	return if $now - $slack_user_map_update < $slack_user_map_interval;

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


my $slack_bot;
my $slack_last_connection_start = 0;
my $slack_bot_ready;

sub slack_start{
	
	# 既に接続しているなら何もしない
	if( $slack_bot ){
		# console "Slack: already connected.";
		return;
	}

	# 前回接続開始してから60秒以内は何もしない
	my $now = time;
	my $remain = $slack_last_connection_start + 60 -$now;
	if( $remain > 0 ){
		console "Slack: waiting $remain seconds to restart connection.";
		return;
	}
	$slack_last_connection_start = $now;

	$slack_bot_ready = 0;

	console "Slack: connection start..";

	$slack_bot = SlackBot->new(
		token => $slack_bot_token,
		ping_interval => 60,
		cb_error => sub{
			my($error)=@_;
			console "Slack: error: $error";
			$slack_bot->close;
			undef $slack_bot;
		},
		cb_warn => sub{
			my($msg)=join ' ',@_;
			console "Slack: warn: $msg";
		},
	);

	$slack_bot->on(
		'finish' => sub {
			console "Slack: connection finished.";
			$slack_bot->close;
			undef $slack_bot;
			undef $slack_bot_ready;
		}
	);
	$slack_bot->on(
		'hello' => sub {
			console "Slack: connection ready.";
			$slack_bot_ready = 1;
		}
	);

	$slack_bot->on(
		'message' => sub {
			my($rtm, $message) = @_;
			eval{
				$message->{subtype}='' if not defined $message->{subtype};
				if( $message->{subtype} eq 'message_changed'){
					my $old_channel = $message->{channel};
					$message = $message->{message};
					$message->{channel} = $old_channel if not $message->{channel};
					$message->{subtype}='' if not defined $message->{subtype};
				}

				if( not $message->{user} ){
					console "missing user? %s",Data::Dump::dump($message);
					$message->{user}='?';
				}

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

				# メッセージの宛先が定義されていて、しかし目的のチャンネルでないなら無視する
				if( $message->{channel} and $message->{channel} ne $slack_channel_id ){
					console "destination not matcn. %s",Data::Dump::dump($message);
					return;
				}

				# subtype によっては特殊な出力が必要
				if( $message->{subtype} eq "channel_join" ){
					relay_to_irc( "${from} さんが参加しました");
				}elsif( $message->{subtype} eq "channel_leave" ){
					relay_to_irc( "${from} さんが退出しました");
				}else{
					console "missing subtype? %s",Data::Dump::dump($message) if $message->{subtype};
				
					my $from =  (not defined $member ) ? $message->{user} : $member->{name};

					my $msg = $message->{text};
					if( defined $message->{message} and not defined $msg ){
						$msg = $message->{message}{text};
					}
					
					if( dnl $msg ){
						my @lines = split /[\x0d\x0a]+/,decode_slack_message($msg);
						for my $line (@lines){
							next if not dnl $line;
							relay_to_irc( "<$from> $line");
						}
					}
				}
			};
			$@ and console $@;
		}
	);

	$slack_bot->start;
}



sub decode_slack_message{
	my($src) = @_;
	console $src;
	
	my $after = "";
	my $start = 0;
	my $end = length $src;
	while( $src =~ /<([^>]*)>/g ){
		my $link = $1;
		$after .= decode_slack_entity( substr($src,$start,$-[0] - $start) );
		$start = $+[0];
		#
		if( $link =~ /([\#\@])[^\|]*\|(.+)/ ){
			$after .= decode_slack_entity( $1.$2 );
		}elsif( $link =~ /[^\|]*\|(.+)/ ){
			$after .= decode_slack_entity( $1 );
		}else{
			$after .= decode_slack_entity( $link );
		}
	}
	$start < $end and $after .= decode_slack_entity( substr($src,$start,$end -$start ) );

	return $after;
}

sub decode_slack_entity{
	my($msg)=@_;
	$msg =~ s/&lt;/</g;
	$msg =~ s/&gt;/>/g;
	$msg =~ s/&amp;/&/g;
	return $msg;
}

my @cue;
my $cue_oldest_time;


# slackのチャンネルにメッセージを送る
sub relay_to_slack{
	my($msg)=@_;
	# $msg はUTF8フラグつきの文字列
	eval{
		$msg =~ s/&/&amp;/g;
		$msg =~ s/</&lt;/g;
		$msg =~ s/>/&gt;/g;

		$cue_oldest_time = time if not @cue;
		push @cue,$msg;
	}
}

sub flush_cue{
	return if not @cue;
	return if not $slack_bot or not $slack_bot_ready;

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
			console "%s: disconnected. reason=$reason";
		},

		# 接続できた
		connect=> sub{
			my ($con,$error) = @_;
			my $bot = $con->heap->{bot};
			if( $error ){
				console "%s: connection failed. error=$error",$bot->{Name};
			}else{
				console "%s: connected to %s:%s. please wait authentication..",$bot->{Name},$con->{host},$con->{port};
				$con->send_msg (NICK => $bot->{ServerSpec}{Nick});
				$con->send_msg (USER => $bot->{ServerSpec}{Username}, '*', '0',$bot->{encode}($bot->{ServerSpec}{Ircname}));
			}
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
	
	if( not grep {$_ eq $channel} keys %{ $bot->{JoinChannelFixed} } ){
		console "指定チャンネル宛てではないので無視します";
		return;
	}
	
	
	my $is_notice = ($command =~ /notice/i);
	if( $is_notice and $slack_dont_relay_notice ){
		console "NOTICEをリレーしない設定なので無視します";
		return;
	}

	my $is_action = 0;
	if( $msg =~ s/\A\x01ACTION\s+(.+)\x01\z/$1/ ){
		$is_action = 1;
	}

	$bot->{user_prefix} =~ /^([^!]+)/;
	my $my_nick = $1;

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

sub bot_connect($){
	my($bot)=@_;
	if( $bot->{irc}->is_connected ){
		# console "%s: already connected. ",$bot->{Name};
		return;
	}else{
		my $now = time;
		if( $now - $bot->{last_connection_start} >= 60 ){
			$bot->{last_connection_start} = $now;
			console "%s: connection start. %s:%s",$bot->{Name}, $bot->{ServerSpec}{Server},$bot->{ServerSpec}{Port};
			$bot->{irc}->connect( $bot->{ServerSpec}{Server},$bot->{ServerSpec}{Port});
		}
	}
}

sub bot_ping($){
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
			if( grep {$_ eq $msg } @duplicate_check ){
				console "SlackToIRC: omit duplicate message $msg";
				return;
			}
			push @duplicate_check,$msg;
			shift @duplicate_check if @duplicate_check > 10;

			console "SlackToIRC: $relay_irc_channel $msg ";
			$relay_irc_bot->{irc}->send_msg( NOTICE => $relay_irc_channel , $relay_irc_bot->{encode}($msg) );
		}
	};
	$@ and console $@;
}

################################################################################
# タイマー

my $timer = AnyEvent->timer(
	interval => 1 , cb => sub {
		{
			my $bot = $config->{irc_server};

			# IRC接続のリトライ
			bot_connect( $bot );

			# 既に接続しているなら一定時間でPINGを送る
			bot_ping($bot);
		}

		# ユーザ名キャッシュを定期的に更新する
		update_slack_cache();

		# Slack接続のリトライ
		slack_start();
		
		flush_cue();
	}
);

###############################

my $c = AnyEvent->condvar;
$c->wait;
exit 0;
