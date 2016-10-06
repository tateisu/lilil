package IRCBot;
$IRCBot::VERSION = '0.161002'; # YYMMDD

use v5.14;
use strict;
use warnings;
use Encode;
use Data::Dump qw(dump);

use ConfigUtil;
use IRCUtil;
use IRCConnection;

use JIS4IRC;

my %config_keywords = ConfigUtil::parse_config_keywords(qw(
	name:s
	server:s
	nick:s
	user_name:s
	real_name:s

	port:d
	ping_interval:d
	flood_protection_penalty_time_max:do
	flood_protection_penalty_time_privmsg:do
	flood_protection_penalty_time_mode:do
	flood_protection_penalty_time_other:do
	flood_protection_penalty_chars_per_second:do
	flood_protection_test_privmsg:ao
	flood_protection_test_op:ao
	
	auto_join:a
	auto_op:a
	ignore_user:a

	is_jis:b
	disabled:b
	fp_test:b
));

sub check_config{
	return ConfigUtil::check_config_keywords(\%config_keywords,@_);
}

###########################################################

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
	'irc_333', # channel creator
	'irc_nick', # ニックネーム変更
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

			# 送信キューを吐き出す
			$self->_flush_send_cue();



			if( $self->{conn} && $self->{server_prefix} ){
				# 接続済みで001メッセージを受け取った後なら、たまにPINGを送る
				
				# smart ping
				my $last_time = ( $self->{last_ping_sent} > $last_read ? $self->{last_ping_sent} : $last_read );
				if( $now - $last_time >= $self->{config}{ping_interval} ){
					$self->{last_ping_sent} = $now;
					$self->{logger}->v("sending ping.");
					$self->send( PING =>  $self->{server_prefix} );
				}
				
				my $test;
				
				$test = $self->{config}{flood_protection_test_privmsg};
				if($test and $self->{fp_penalty_time} < $self->{fp_penalty_time_max} ){
					my $irc_channel = $self->find_channel_by_name( IRCUtil::lc_irc(IRCUtil::fix_channel_name($test->[0],0)));
					if( $irc_channel ){
						$self->send( PRIVMSG => $irc_channel->{channel_raw},$self->{encode}($test->[1]));
					}
				}
				
				$test = $self->{config}{flood_protection_test_op};
				if($test and $self->{fp_penalty_time} < $self->{fp_penalty_time_max} ){
					my $irc_channel = $self->find_channel_by_name( IRCUtil::lc_irc(IRCUtil::fix_channel_name($test->[0],0)));
					if( $irc_channel ){
						$self->send( MODE => $irc_channel->{channel_raw} , "+o",$self->{encode}($test->[1]));
					}
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

	
	{
		my( $iv );
		$self->{fp_tx_cue} =[];
		$self->{fp_last_decrease} = time;
		$self->{fp_penalty_time} = 0;
		
		
		# ペナルティタイムの上限。これを超えないように待ってから発言する
		$iv = $self->{config}{flood_protection_penalty_time_max};
		$iv = 512 if not defined $iv or $iv <= 0;
		$self->{fp_penalty_time_max} = $iv;

		# privmsgを送るときの発言ペナルティ。これとメッセージ長さのペナルティの合計が、メッセージのペナルティとなる
		$iv = $self->{config}{flood_protection_penalty_time_privmsg};
		$iv = 2 if not defined $iv or $iv <= 0;
		$self->{fp_penalty_privmsg} = $iv;

		# modeを送るときの発言ペナルティ。これとメッセージ長さのペナルティの合計が、メッセージのペナルティとなる
		$iv = $self->{config}{flood_protection_penalty_time_mode};
		$iv = 4 if not defined $iv or $iv <= 0;
		$self->{fp_penalty_mode} = $iv;

		# 他のコマンドを送るときの発言ペナルティ。これとメッセージ長さのペナルティの合計が、メッセージのペナルティとなる
		$iv = $self->{config}{flood_protection_penalty_time_other};
		$iv = 3 if not defined $iv or $iv <= 0;
		$self->{fp_penalty_other} = $iv;

		# メッセージのバイト数に応じてかかるペナルティ。ペナルティ1秒あたりのバイト数を指定する
		$iv = $self->{config}{flood_protection_penalty_chars_per_second};
		$iv = 16 if not defined $iv or $iv <= 0;
		$self->{fp_penalty_cps} = $iv;
	}

	$self->{conn} = IRCConnection->new();

	my $auto_op = sub{
		my($conn,$channel_raw,$channel,$target) = @_;
		my $re = IRCUtil::match_prefix_re_list( $target,$self->{config}{auto_op} );
		if($re){
			$target =~ /^([^!]+)/;
			my $target_nick = $1;
			$self->{logger}->i("%s +o %s by auto_op %s",$channel,$target_nick,$re);
			$self->send( MODE => $channel_raw , "+o",$target_nick );
			return 1;
		}
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
			$self->send(NICK => $self->{config}{nick});
			$self->send(USER => $self->{config}{user_name}, '*', '0',$self->{encode}($self->{config}{real_name}));
		},

		$IRCConnection::EVENT_TX_READY=> sub{
			my($conn,$event_type) = @_;
			$self->_flush_send_cue();
		},

		# Nickname is already in use.
		irc_433 => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			$self->{logger}->w("Nickname is already in use. retry NICK..");
			my $nick = $self->{config}{nick};
			my $len = length($nick);
			$len > 7 and $nick = substr($nick,0,7);
			$nick .= sprintf("%02d",int rand 100);
			$self->send(NICK => $nick);
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
		[qw( irc_376 irc_422 )] => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			$self->{logger}->i("end of MOTD.");
			for my $channel (keys %{ $self->{JoinChannelFixed} } ){
				$self->{logger}->i("try join to $channel");
				$self->send( JOIN => $self->{encode}( $channel ) );
			}
			for my $channel (keys %{ $self->{CurrentChannel} } ){
				$self->{logger}->i("try join to $channel");
				$self->send( JOIN => $self->{encode}( $channel ) );
			}
		},
		
		irc_join => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			my $from = $args->{prefix}; # joinした人
			my $channel_raw = $args->{params}[0];
			my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);
			
			if( $from eq $self->{user_prefix} ){
				$self->{logger}->i("%s: join %s",$channel,$from);
				$self->{JoinChannelFixed}{$channel} or $self->{CurrentChannel}{$channel}=1;
				
				$self->channel_update( $channel_raw,$channel );
			}else{
				# auto-op check
				$auto_op->($conn,$channel_raw,$channel,$from);
			}
		},
		
		irc_kick => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)
			#
			my $from = $args->{prefix}; # kickした人
			
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
			$self->send( PONG => @{ $args->{params} } );
		},

		irc_invite => sub{
			my($conn,$event_type,$args) = @_; # args は無名ハッシュ :<prefix> <command> [params] (params contains trail part)

			my $from = $args->{prefix}; # inviteした人
			my $channel_raw = $args->{params}[0];
			my $channel = IRCUtil::fix_channel_name($self->{decode}($channel_raw),1);
			
			$self->{logger}->i("invited to %s by %s",$channel,$from );
			$self->send( JOIN => $channel_raw );
		},

		# メッセージ処理
		[qw( irc_privmsg irc_notice )] => sub{
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

			my $ignore_re = IRCUtil::match_prefix_re_list( $from , $self->{config}{ignore_user} );
			$ignore_re and return $self->{logger}->i("igonre_user $from by $ignore_re");
		
			# pingコマンド
			if( $my_nick ){
				if( $msg =~ /\A\s*$my_nick>ping\s*\z/i ){
					$self->send( NOTICE => $channel_raw ,$self->{encode}( sprintf "%s>pong." ));
					return;
				}elsif( $msg =~ /\A\s*$my_nick>status\s*\z/i ){
					my @status = $self->{cb_status}();
					for( @status ){
						$self->send( NOTICE => $channel_raw ,$self->{encode}($_));
					}
					return;
				}
			}
			
			##################################

			if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>op\s*\z/ ){
				$auto_op->($conn,$channel_raw,$channel,$from) or $self->send( NOTICE => $channel_raw ,$self->{encode}( sprintf "%s>not match.",$from_nick ));
				return;
			}

			if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>exit\s*\z/ ){
				$self->{logger}->i("%s: exit required by (%s),said (%s)",IRCUtil::fix_channel_name($self->{decode}($channel),1),$from,$msg);
				$self->send( PART => $channel_raw );
				return;
			}

			
			$self->{cb_relay}->( $self, $from_nick,$command,$channel_raw, $channel, $msg );
			
		},

		
	);
	
	$self->{logger}->i("connection start. %s:%s", $self->{config}{server},$self->{config}{port});
	$self->{conn}->connect( $self->{config}{server},$self->{config}{port});
}

sub is_ready{
	my $self = shift;
	not $self->{is_disposed} and $self->{conn} and $self->{conn}->is_ready;
}


sub _flush_send_cue{
	my $self = shift;

	my $cue = $self->{fp_tx_cue};
	return if not @$cue;

	# 前回からの時間経過を測定する
	my $now = time;
	my $delta = $now - $self->{fp_last_decrease};
	$self->{fp_last_decrease} = $now;

	# ペナルティタイムを減少させる
	if( $delta > 0 and $self->{fp_penalty_time} > 0 ){
		my $v = $self->{fp_penalty_time} - $delta;
		$self->{fp_penalty_time} = $v <= 0 ? 0 : $v;
	}

	my $line = $cue->[0];
	my $line_penalty = $line->[0];
	my $remain = $self->{fp_penalty_time} + $line_penalty - $self->{fp_penalty_time_max};
	$remain > 0 and return $self->{logger}->d("flood protection: waiting %s seconds. penalty_time=%d, line_penalty=%d",$remain,$self->{fp_penalty_time},$line_penalty);
	
	$self->{fp_penalty_time} += $line_penalty;
	shift @$cue;
	shift @$line;
	eval{ $self->{conn}->send( @$line ); };
	$@ and $self->{logger}->i("send failed. %s",$@);
}




sub send{
	my $self = shift;

	my $command = $_[0];
	my $line_length = length( join(' ',@_)) +2 +(@_>=2? 1: 0 );
	if( $line_length > 0 ){
		
		my $penalty_chars_per_seconds = $self->{fp_penalty_cps};
		
		my $line_penalty = 
			( $command =~ /\A(?:privmsg|notice)\z/ ? $self->{fp_penalty_privmsg}
			: $command =~ /\A(?:mode)\z/ ? $self->{fp_penalty_mode}
			: $self->{fp_penalty_other}
			) + int( ($line_length + $penalty_chars_per_seconds -1 )/ $penalty_chars_per_seconds );

		$self->{logger}->d("line_penalty=%s,command=%s,length=%s,current_penalty=%d",$line_penalty,$command,$line_length,$self->{fp_penalty_time});

		push @{ $self->{fp_tx_cue} } , [$line_penalty, @_];
		$self->_flush_send_cue();
	}
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
