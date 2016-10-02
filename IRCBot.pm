package IRCBot;
$IRCBot::VERSION = '0.161002'; # YYMMDD

use v5.14;
use strict;
use warnings;

use IRCUtil;
use IRCConnection;

use Encode;
use JIS4IRC;

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

sub new {
	my $class = shift;

	return bless {
		logger => Logger->new(prefix=>"IRCBot:"),
		last_connection_start =>0,
		last_ping_sent => time,
		cb_relay => sub{},
		cb_channel => sub{},
		
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

		if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*$my_nick>exit\s*\z/ ){
			$self->{logger}->i("%s: exit required by (%s),said (%s)",IRCUtil::fix_channel_name($self->{decode}($channel),1),$from,$msg);
			$conn->send( PART => $channel_raw );
			return;
		}

		
		$self->{cb_relay}->( $self, $from_nick,$command,$channel_raw, $channel, $msg );
		
	};

	$self->{conn}->on(

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
				for my $re (@{ $self->{config}{auto_op} }){
					if( $from =~ /$re/ ){
						$from =~ /^([^!]+)/;
						$self->{logger}->i("%s: +o to %s",$channel,$1);
						$self->send( MODE => $channel_raw , "+o",$1 );
						last;
					}
				}
			}else{
				$self->{logger}->i("%s: join %s",$channel,$from);
				$self->{JoinChannelFixed}{$channel} or $self->{CurrentChannel}{$channel}=1;
				
				$self->{cb_channel}( $self, $channel_raw,$channel );
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



1;
__END__