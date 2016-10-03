package IRCBot;
$IRCBot::VERSION = '0.161002'; # YYMMDD

use v5.14;
use strict;
use warnings;

use Encode;
use Data::Dump qw(dump);

use IRCUtil;
use IRCConnection;

use JIS4IRC;

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

sub new {
	my $class = shift;

	return bless {
		logger => Logger->new(prefix=>"IRCBot:"),
		last_connection_start =>0,
		last_ping_sent => time,
		channel_map =>{},
		cb_relay => sub{},
		cb_status => sub{},
		@_,
	}, $class;
}

sub dispose{
	my $self = shift;
	$self->{is_disposed} = 1;
	$self->{conn} and $self->{conn}->dispose;
}

sub config{
	my($self,$config_new)=@_;
	if( $config_new ){
		$self->{config} = $config_new;
		my $name = $self->{config}{name} // '?';
		$self->{logger}->prefix( "I\[$name\]" );
	}
	return $self->{config};
}

# static method
sub check_config{
	my($config,$logger)=@_;

	my $valid = 1;
	
	for( qw( name ping_interval server port nick user_name real_name auto_join auto_op )){
		if( not $config->{$_} ){
			$logger->e( "config error: missing $_" );
			$valid = 0;
		}
	}
	for( qw( is_jis )){
		if( not exists $config->{$_} ){
			$logger->e( "config error: missing $_" );
			$valid = 0;
		}
	}
	return $valid;
}

###########################################################
# IRC接続の管理

sub status{
	my $self = shift;

	return "not connected" if not $self->{conn} or not $self->{conn}->is_active;
	return "connecting" if $self->{conn}{busy_connect};
	return "authorizing" if not $self->{server_prefix};
	
	my @lt = localtime($self->{conn}->last_read);
	return sprintf("connected. last_rx=%d:%02d:%02d",reverse @lt[0..2]);
}

our %catch_up_ignore = map{ ($_,1) } (
	'<>buffer_empty',
	'irc_020',  #Please wait while we process your connection.
	'irc_002', # Your host is irc.livedoor.ne.jp, running version 2.11.2p3
	'irc_003', # This server was created Sat Aug 20 2016 at 15:04:35 JST
	'irc_004', # modeフラグの一覧とか色々
	'irc_005', # サーバのビルド時設定など
	'irc_042', # your unique ID
	'irc_251', # There are 38466 users and 4 services on 27 servers
	'irc_252', # 81 operators online
	'irc_253', # 4 unknown connections
	'irc_254', # 23896 channels formed
	'irc_255', # I have 3389 users, 0 services and 1 servers
	'irc_265', # Current local users 3389, max 3794
	'irc_266', # Current global users 38466, max 39236
	'irc_375', # - irc.livedoor.ne.jp Message of the Day -
	'irc_372', # motd line
	'irc_353', # NAMES reply
	'irc_366', # "End of NAMES list.
	'irc_482', # You're not channel operator
	'irc_pong', # 
	'irc_mode', # 
	'irc_332', # topic
	'irc_topic', # topic
	'irc_part', # 退出
);


sub on_timer{
	my $self = shift;

	my $now = time;
	if( $self->{conn} ){
		my $last_read = $self->{conn}->last_read;
		my $delta = $now - $last_read;
		if( $delta > $self->{config}{ping_interval} * 3 ){
			# 受信データが途切れた
			$self->{logger}->e("ping timeout.");
			$self->{conn}->dispose;
			undef $self->{conn};
			# fall thru.
		}else{
			# 接続済みで001メッセージを受け取った後なら、たまにPINGを送る
			if( $self->{conn} && $self->{server_prefix} ){
				# smart ping
				my $last_time = ( $self->{last_ping_sent} > $last_read ? $self->{last_ping_sent} : $last_read );
				if( $now - $last_time >= $self->{config}{ping_interval} ){
					$self->{last_ping_sent} = $now;
					$self->{logger}->v("sending ping.");
					$self->{conn}->send( PING =>  $self->{server_prefix} );
				}
			}
			
			# 
			return;
		}
	}

	# 前回接続開始して一定時間以内は何もしない
	my $remain = $self->{last_connection_start} + 60 -$now;
	$remain > 0 and return $self->{logger}->d("waiting %d seconds to restart connection.",$remain);
	$self->{last_connection_start} = $now;

	undef $self->{server_prefix};

	if($self->{config}{is_jis} ){
		$self->{encode} = sub{ JIS4IRC::fromEUCJP( $eucjp->encode($_[0])); };
		$self->{decode} = sub{ $eucjp->decode( JIS4IRC::toEUCJP(  $_[0])); };
	}else{
		$self->{encode} = sub{ $utf8->encode($_[0]); };
		$self->{decode} = sub{ $utf8->decode($_[0]); };
	}

	# チャネル名を正規化しておく
	$self->{JoinChannelFixed} = {
		map{ ( IRCUtil::fix_channel_name($_,0),1 ) }
		@{$self->{config}{auto_join}}
	};


	$self->{conn} = IRCConnection->new();

	my $auto_op = sub{
		my($conn,$channel_raw,$channel,$target) = @_;

		$target =~ /^([^!]+)/;
		my $target_nick = $1;
		
		for my $re (@{ $self->{config}{auto_op} }){
			if( $target =~ /$re/ ){
				$target =~ /^([^!]+)/;
				$self->{logger}->i("%s: +o to %s",$channel,$target_nick);
				$self->send( MODE => $channel_raw , "+o",$target_nick );
				return 1;
			}
			$self->{logger}->d("auto_op not match. %s %s",$target,$re);
		}
		
		return 0;
	};

	my $on_motd = sub{
		my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
		#
		$self->{logger}->i("end of MOTD.");
		for my $channel (keys %{ $self->{JoinChannelFixed} } ){
			$self->{logger}->i("try join to $channel");
			$conn->send( JOIN => $self->{encode}( $channel ) );
		}
		for my $channel (keys %{ $self->{CurrentChannel} } ){
			$self->{logger}->i("try join to $channel");
			$conn->send( JOIN => $self->{encode}( $channel ) );
		}
	};
	
	my $on_message = sub{
		my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)

		my $from = $args->{prefix};
		my $command = $args->{command};

		my $channel_raw = $args->{params}[0];
		if(ref $channel_raw ){
			$channel_raw = shift @$channel_raw;
		}
		my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);

		my $msg = $self->{decode}( $args->{params}[-1]);

		$self->{logger}->i("%s %s %s %s",$command,$from,$channel,$msg);

		##############################

		$self->{user_prefix} =~ /^([^!]+)/;
		my $my_nick = $1;

		$from =~ /^([^!]+)/;
		my $from_nick = $1;

		# pingコマンド
		if( $my_nick ){
			if( $msg =~ /\A\s*$my_nick>ping\s*\z/i ){
				$conn->send( NOTICE => $channel_raw ,$self->{encode}( sprintf "%s>pong." ));
				return;
			}elsif( $msg =~ /\A\s*$my_nick>status\s*\z/i ){
				my @status = $self->{cb_status}();
				for( @status ){
					$conn->send( NOTICE => $channel_raw ,$self->{encode}($_));
				}
				return;
			}
		}
		
		##################################

		if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>op\s*\z/ ){
			$auto_op->($conn,$channel_raw,$channel,$from) or $conn->send( NOTICE => $channel_raw ,$self->{encode}( sprintf "%s>not match.",$from_nick ));
			return;
		}

		if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>exit\s*\z/ ){
			$self->{logger}->i("%s: exit required by (%s),said (%s)",IRCUtil::fix_channel_name($self->{decode}($channel),1),$from,$msg);
			$conn->send( PART => $channel_raw );
			return;
		}

		
		$self->{cb_relay}->( $self, $from_nick,$command,$channel_raw, $channel, $msg );
		
	};

	$self->{conn}->on(

		$IRCConnection::EVENT_CATCH_UP=> sub{
			my($conn,$event_type,@args) = @_;
			if( not $event_type){
				use Carp;
				confess("empty event_type");
			}else{
				return if $catch_up_ignore{$event_type};
				$self->{logger}->i("catch up. %s,%s",$event_type,dump(\@args));
			}
		},
		

		$IRCConnection::EVENT_ERROR => sub {
			my(undef,$event_type,$error) = @_;
			$self->{logger}->i("connection failed. error=%s",$error);
			$self->{conn}->dispose;
			undef $self->{conn};
		},

		#接続終了
		$IRCConnection::EVENT_DISCONNECT => sub {
			my(undef,$event_type,$reason) = @_;
			$self->{logger}->i("disconnected. reason=$reason");
			$self->{conn}->dispose;
			undef $self->{conn};
		},

		# 接続できた
		$IRCConnection::EVENT_CONNECT=> sub{
			my($conn,$event_type) = @_;
			$self->{logger}->i("connected. please wait authentication.");
			$conn->send(NICK => $self->{config}{nick});
			$conn->send(USER => $self->{config}{user_name}, '*', '0',$self->{encode}($self->{config}{real_name}));
		},

		# Nickname is already in use.
		irc_433 => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			$self->{logger}->w("Nickname is already in use. retry NICK..");
			my $nick = $self->{config}{nick};
			my $len = length($nick);
			$len > 7 and $nick = substr($nick,0,7);
			$nick .= sprintf("%02d",int rand 100);
			$conn->send(NICK => $nick);
		},

		# 認証完了
		irc_001 => sub {
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			my $from = $args->{prefix}; # サーバ名
			my $line = $self->{decode}( $args->{params}[-1]);
			$self->{logger}->i("001 from=%s line=%s",$from,$line);
			
			# 自分のprefixを覚えておく
			$self->{server_prefix} = $from;
			$line =~ /(\S+\!\S+\@\S+)/ and $self->{user_prefix} = $1;
		},

		# MOTD終了
		irc_376 => $on_motd, # end of MOTD
		irc_422 => $on_motd, # no MOTD

		irc_join => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			my $from = $args->{prefix}; # joinした人
			my $channel_raw = $args->{params}[0];
			my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);
			
			if( $from ne $self->{user_prefix} ){
				# 他人のjoin
				# auto-op check
				$auto_op->($conn,$channel_raw,$channel,$from);
			}else{
				$self->{logger}->i("%s: join %s",$channel,$from);
				$self->{JoinChannelFixed}{$channel} or $self->{CurrentChannel}{$channel}=1;
				
				$self->channel_update( $channel_raw,$channel );
			}
		},
		
		irc_kick => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			my $from = $args->{prefix}; # joinした人
			
			my $line = $self->{encode}( $args->{params}[0]);
			my $channel_raw = $args->{params}[0];
			my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);
			my $who = $args->{params}[1];
			my $msg = $self->{decode}( $args->{params}[-1] );

			$self->{user_prefix} =~ /^([^!]+)/;
			my $my_nick = $1;

			if( lc_irc($who) eq lc_irc($self->{user_prefix})
			or	lc_irc($who) eq lc_irc($my_nick)
			){
				# 自分がkickされた
				$self->{logger}->i("%s: kicked (%s) by (%s) %s",$channel,$who,$from,$msg);
				delete $self->{CurrentChannel}{$channel};
			}else{
				# 他人がkickされた
			}
		},
		
		irc_quit=> sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			$self->{logger}->i("quit. %s %s",$args->{prefix},$args->{params}[0]);
		},
		
		irc_ping =>sub {
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			$self->{last_ping_sent} = $now;
			$self->{logger}->v("ping received. returns pong.");
			$self->{conn}->send( PONG => @{ $args->{params} } );
		},

		irc_invite => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)

			my $from = $args->{prefix}; # inviteした人
			my $channel_raw = $args->{params}[0];
			my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);
			
			$self->{logger}->i("invited to %s by %s",$channel,$from );
			$conn->send( JOIN => $channel_raw );
		},

		# メッセージ処理
		irc_privmsg => $on_message,
		irc_notice => $on_message,
		
	);
	
	$self->{logger}->i("connection start. %s:%s", $self->{config}{server},$self->{config}{port});
	$self->{conn}->connect( $self->{config}{server},$self->{config}{port});
}

sub is_ready{
	my $self = shift;
	not $self->{is_disposed} and $self->{conn} and $self->{conn}->is_ready;
}

# $msg は UTF8フラグつきの文字列であること
sub send{
	my $self = shift;
	eval{
		$self->{conn}->send( @_ );
	};
	$@ and $self->{logger}->i("send failed. %s",$@);
}


sub channel_update{
	my( $self, $channel_raw,$channel ) = @_;

	my $channel_lc = IRCUtil::lc_irc($channel);
	$self->{channel_map}{ $channel_lc } = {
		channel => $channel,
		channel_raw => $channel_raw,
		channel_lc => $channel_lc,
	};
	$self->{logger}->v("channel %s",$channel);
}
sub find_channel_by_name{
	my($self,$name_lc)=@_;
	return $self->{channel_map}{ $name_lc };
}

1;
__END__

	# find channel
	my $v = $irc_channels{ $irc_bot->{config}{name}."<>".$channel_lc};
	$v or return $logger->w("unknown IRC channel: %s %s",$irc_bot->{config}{name},$channel);

		
		#my %irc_channels;
			cb_channel => \&cb_irc_channel,
		my $irc_to = $irc_channels{  ."<>". $relay->{irc_channel_lc}};
		if(not $irc_to){
			$logger->w("unknown irc channel: %s %s",$relay->{irc_conn} , $relay->{irc_channel_lc});
			next;
		}

		#
		my $irc_bot = $irc_to->{bot};
		


