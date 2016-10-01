package SlackBot;
$SlackBot::VERSION = '0.160928'; # YYMMDD

use v5.14;
use strict;
use warnings;

use Attribute::Constant;
use JSON;
use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;
use AnyEvent::HTTP;

my $URL_RTM_START = 'https://slack.com/api/rtm.start';
my $URL_CHANNEL_LIST = "https://slack.com/api/channels.list";
my $URL_USER_LIST = "https://slack.com/api/users.list";

sub new {
	my $class = shift;

	return bless {
		client	 => AnyEvent::WebSocket::Client->new,
		registry => {},
		ping_interval => 60,
		metadata => {},
		last_event_received => time,
		user_agent => "SlackBot.pm",
		@_,
	#	token	 => $token,
	}, $class;
}

sub dispose{
	my $self = shift;
	$self->{is_disposed} = 1;
	$self->{registry} = {};
	$self->close;
}

sub quiet {
	my $self = shift;

	@_ and $self->{quiet} = shift;

	$self->{quiet} // '';
}

sub user_agent{
	my $self = shift;

	@_ and $self->{user_agent} = $_[0] // "SlackBot.pm";

	$self->{user_agent};
}

sub metadata { shift->{metadata} // {} }

#########################################################################
# イベントリスナーの管理

# ハンドラが登録されていないイベントのキャッチアップ。引数は実際のイベントタイプによって異なる
our $EVENT_CATCH_UP : Constant( '<>catch_up');

# 非同期処理でエラーがあった場合に発生するイベント。引数はエラーメッセージ
our $EVENT_ERROR : Constant( '<>error');

# 送信したメッセージに対するタイムスタンプが確定したら呼ばれる。引数はレスポンスのJSONオブジェクト
our $EVENT_REPLY_TO : Constant( '<>reply_to');

# typeのない未知のメッセージを受け取った。引数はレスポンスのJSONオブジェクト
our $EVENT_UNKNOWN_MESSAGE : Constant( '<>unknown_message');

# RTM API のWebSocket 接続が閉じられた
our $EVENT_RTM_CONNECTION_FINISHED : Constant( '<>finish');


# rmt.startのレスポンスや各種Web APIのレスポンスが通知される。引数はデータのJSON配列。レスポンス全体ではない
our $EVENT_SELF : Constant( '<>self');
our $EVENT_TEAM : Constant( '<>team');
our $EVENT_USERS : Constant( '<>users');
our $EVENT_CHANNELS : Constant( '<>channels');
our $EVENT_GROUPS : Constant( '<>groups');
our $EVENT_MPIMS : Constant( '<>mpims');
our $EVENT_IMS : Constant( '<>ims');
our $EVENT_BOTS : Constant( '<>bots' );

# ほか、https://api.slack.com/events に説明されているイベントタイプを指定できる。
# 引数はレスポンスのJSONオブジェクト

# イベントハンドラの登録
sub on {
	my $self = shift;
	my $size = 0+@_;
	for( my $i=0 ; $i<$size-1 ; $i+=2 ){
		my $type = $_[$i];
		my $cb = $_[$i+1];
		$self->{registry}{$type} = $cb;
	}
}

# イベントハンドラの除去
sub off {
	my $self = shift;
	for(@_){
		delete $self->{registry}{$_};
	}
}

# イベント発火
sub _fire {
	my ($self, $type, @args) = @_;
	my $cb = $self->{registry}{$type};
	$cb or $cb = $self->{registry}{$EVENT_CATCH_UP};
	$cb and $cb->($self, $type, @args);
}

# Web APIで取得したデータのイベント発火
sub _update_info{
	my($self,$key,$data,$event_name)=@_;
	return if not defined $data;

	$self->{metadata}{$key} = $data;
	$self->_fire( $event_name ,$data );
}

#########################################################################
# WebSocket を使った RTM 接続

sub status{
	my $self = shift;
	return "calling rtm.start" if $self->{busy_rtm_start};
	return "connecting WebSocket" if $self->{busy_wss_connect};
	return "not connected" if not $self->{conn};
	return "waiting hello" if not $self->{said_hello};
	my @lt = localtime;
	return sprintf("connected. last_rx=%d:%02d:%02d",reverse @lt[0..2]);
}

sub is_active{
	my $self = shift;
	return $self->{busy_rtm_start} or $self->{busy_wss_connect} or $self->{conn};
}

sub is_ready{
	my $self = shift;
	return $self->{conn} and $self->{said_hello};
}

sub is_ping_timeout {
	my $self = shift;
	my $delta = time - $self->{last_event_received};
	if( $self->{conn} and $delta > $self->{ping_interval} * 3 ){
		warn "is_ping_timeiut: last=$self->{last_event_received}, ping_interval=$self->{ping_interval}, delta=$delta\n";
		return 1;
	}
	return 0;
}

sub close {
	my ($self)=@_;
	eval{ $self->{conn}->close };
	undef $self->{conn};
	undef $self->{pinger};
}

sub start {
	my($self) = @_;

	$self->{last_event_received} = time;
	$self->{busy_rtm_start} = 1;
	$self->{busy_wss_connect} = 0;
	$self->{said_hello} = 0;

	http_get $URL_RTM_START .'?token='. $self->{token}
	, headers => {
		'User-Agent',$self->{user_agent}
	}
	, sub {
		my($data,$headers)=@_;

		$self->{is_disposed} and return;

		$self->{busy_rtm_start} = 0;
		$self->{last_event_received} = time;

		(defined $data and length $data)
		or return $self->_fire( $EVENT_ERROR, "HTTP error. $headers->{Status} $headers->{Reason}");

		my $json = eval{ decode_json($data) };
		$@ and return $self->_fire( $EVENT_ERROR, "JSON parse error. $@");

		$json->{ok} or return $self->_fire( $EVENT_ERROR, "rtm.start API returns error. $json->{error}" );

		$self->{metadata} = $json;

		#
		$self->_update_info( 'self',$json->{self} , $EVENT_SELF );
		$self->_update_info( 'team',$json->{team} , $EVENT_TEAM );
		$self->_update_info( 'users',$json->{users} , $EVENT_USERS );
		$self->_update_info( 'channels',$json->{channels} ,  $EVENT_CHANNELS );
		$self->_update_info( 'groups',$json->{groups} , $EVENT_GROUPS );
		$self->_update_info( 'mpims',$json->{mpims}  ,  $EVENT_MPIMS );
		$self->_update_info( 'ims',$json->{ims} , $EVENT_IMS );
		$self->_update_info( 'bots',$json->{bots} , $EVENT_BOTS );

		eval{
			$self->{busy_wss_connect} = 1;
			$self->{client}->connect($json->{url})->cb(sub {

				$self->{last_event_received} = time;
				$self->{busy_wss_connect} = 0;

				my $conn = $self->{conn} = eval{ shift->recv };
				$@ and return $self->_fire( $EVENT_ERROR, "WebSocket error. $@");

				$self->{is_disposed} and return $conn->close;

				$self->{message_id_seed} = 1; # 送信メッセージのIDはコネクションごとにユニーク


				$self->{pinger} = AnyEvent->timer(
					after	 => 60,
					interval => $self->{ping_interval},
					cb		 => sub { $self->ping },
				);

				$conn->on(finish => sub { 
					my( $conn ) = @_;

					$self->{last_event_received} = time;

					# Cancel the pinger
					undef $self->{pinger};
					undef $self->{conn};

					$self->_fire($EVENT_RTM_CONNECTION_FINISHED);
				});

				$conn->on(each_message => sub {
					my ($conn, $raw) = @_;

					$self->{is_disposed} and return $conn->close;

					$self->{last_event_received} = time;

					my $json = eval{ decode_json($raw->body) };
					$@ and return $self->_fire( $EVENT_ERROR, "JSON parse error. $@");

					if( $json->{type} ){
						$self->{said_hello}++ if $json->{type} eq 'hello';
						$self->_fire($json->{type}, $json);
						# list of event type : see https://api.slack.com/rtm
					}elsif( $json->{reply_to} ){
						$self->_fire($EVENT_REPLY_TO, $json);
						# 送信したメッセージのtsが確定した
					}else{
						$self->_fire($EVENT_UNKNOWN_MESSAGE, $json);
						# typeのない未知のメッセージを受け取った
					}
				});
			});
		};
		if($@){
			$self->{busy_wss_connect} = 0;
			return $self->_fire( $EVENT_ERROR, "WebSocket error. $@");
		}
	};
}

sub send {
	my ($self, $msg) = @_;
	my $msg_id;
	eval{
		$self->{is_disposed} and return;

		if( not $self->{conn} ){
			warn "Cannot send message. missing RTM connection.";
		}elsif( not $self->{said_hello} ){
			warn "Cannot send message. because Slack has not yet said hello.";
		}else{
			$msg_id = $msg->{id} = $self->{message_id_seed}++;
			my $json = encode_json($msg);
			$self->{conn}->send($json);
		}
	};
	$@ and warn $@;

	return $msg_id;
}

sub ping {
	my ($self, $msg) = @_;
	$self->send({  %{ $msg // {} } ,type => 'ping' } );
}

#######################################################

# Web API の非同期呼び出し
# 呼び出し結果はRTMイベントと同じコールバックで帰る。エラーコールバックは別途指定する
sub _call_list_api{
	my($self,$url,$key,$key2,$event_type,$cb_error)=@_;

	$cb_error //= sub{ };

	http_get "$url?token=$self->{token}"
	, headers => {
		'User-Agent',$self->{user_agent}
	}
	, sub {
		my($data,$headers)=@_;
		
		$data or return $cb_error->("HTTP error. $headers->{Status}, #headers->{Reason}");

		my $json = eval{ decode_json($data)};
		$@ and return $cb_error->( "JSON parse error. $@");

		$json->{ok} or return $cb_error->( "API returns error. $json->{error}");
		
		$self->_update_info( $key,$json->{$key2} ,$event_type );

	};
}

sub get_user_list{
	my($self,$cb_error)=@_;
	$self->_call_list_api($URL_USER_LIST,'users','members',$EVENT_USERS,$cb_error);
}

sub get_channel_list{
	my($self,$cb_error)=@_;
	$self->_call_list_api($URL_CHANNEL_LIST,'channels','channels',$EVENT_USERS,$cb_error);
}

#######################################################

sub encode_entity{
	my $msg = shift;
	$msg =~ s/&/&amp;/g;
	$msg =~ s/</&lt;/g;
	$msg =~ s/>/&gt;/g;
	$msg;
}

sub decode_entity{
	my($msg)=@_;
	$msg =~ s/&lt;/</g;
	$msg =~ s/&gt;/>/g;
	$msg =~ s/&amp;/&/g;
	return $msg;
}

sub decode_message{
	my($src) = @_;
	
	my $after = "";
	my $start = 0;
	my $end = length $src;
	while( $src =~ /<([^>]*)>/g ){
		my $link = $1;
		$after .= decode_entity( substr($src,$start,$-[0] - $start) );
		$start = $+[0];
		#
		if( $link =~ /([\#\@])[^\|]*\|(.+)/ ){
			$after .= decode_entity( $1.$2 );
		}elsif( $link =~ /[^\|]*\|(.+)/ ){
			$after .= decode_entity( $1 );
		}else{
			$after .= decode_entity( $link );
		}
	}
	$start < $end and $after .= decode_entity( substr($src,$start,$end -$start ) );

	return $after;
}


#######################################################
1;
__END__

=pod

=encoding UTF-8

=head1 NAME

SlackBot.pm - AnyEvent module for interacting with the Slack RTM API.

=head1 DESCRIPTION

This provides an L<AnyEvent>-based interface to the L<Slack Real-Time Messaging API|https://api.slack.com/rtm>.
This allows a program to interactively send and receive messages of a WebSocket connection.

This module is similar to AnyEvent::SlackRTM, but more suitable for real-world bot.
- completely non-blocking. using AnyEvent::HTTP to calling Web API (includes rtm.start). this is important to coexist with other AnyEvent module, such as IRC.
- some internal event for error handling. this module does not unexpectly die in asynchronous callback.
- event for catch-up all unregistred events.
- some function to call Web API in asynchronously. some event to notify its response.
- function to check incoming message timeout (almost same as ping timeout).

=head1 SYNOPSIS

sub slack_start{

	if( $slack_bot ){
		return if not $slack_bot->is_ping_timeout;
		console "Slack: ping timeout.";
		$slack_bot->dispose;
		undef $slack_bot;
	}

	my $now = time;
	my $remain = $slack_last_connection_start + 60 -$now;
	if( $remain > 0 ){
		console "Slack: waiting $remain seconds to restart connection.";
		return;
	}
	$slack_last_connection_start = $now;

	console "Slack: connection start..";

	$slack_bot = SlackBot->new(
		token => $config->{slack_bot_api_token},
		user_agent => $config->{slack_user_agent},
		ping_interval => 60,
	);

	$slack_bot->on(

		$SlackBot::EVENT_CATCH_UP => sub {
			my($rtm, $event_type, @args) = @_;
			console "Slack: event=$event_type %s",Data::Dump::dump(\@args);
		},

		$SlackBot::EVENT_RTM_CONNECTION_FINISHED => sub {
			console "Slack: connection finished.";
			$slack_bot->dispose;
			undef $slack_bot;
		},

		$SlackBot::EVENT_ERROR => sub {
			my($sb,$event_type,$error)=@_;
			console "Slack: $error";
			$slack_bot->dispose;
			undef $slack_bot;
		},

		$SlackBot::EVENT_SELF => sub {
			my($rtm, $event_type, $data) = @_;
			$slack_bot_id = $data->{id};
			console "Slack: me: id=$data->{id},name=$data->{name}";
		},

		$SlackBot::EVENT_CHANNELS => sub {
			my($rtm, $event_type, $data) = @_;
		    for my $channel ( @$data ){
				if( "\#$channel->{name}" eq $config->{slack_channel_name} ){
					$slack_channel_id = $channel->{id};
					console "Slack Channel: $channel->{id},\#$channel->{name}";
					last;
				}
			}
			$slack_channel_id or console "missing Slack channel '$config->{slack_channel_name}'";
		},

		$SlackBot::EVENT_USERS => sub {
			my($rtm, $event_type, $data) = @_;
		    for my $member ( @$data ){
				$slack_user_map->{ $member->{id} } = $member;
			}
			console "slack user list size=".scalar(%$slack_user_map);
			$slack_user_map_update = time;
		},

		$SlackBot::EVENT_TEAM => sub {} ,
		$SlackBot::EVENT_GROUPS => sub {} ,
		$SlackBot::EVENT_MPIMS => sub {} ,
		$SlackBot::EVENT_IMS => sub {} ,
		$SlackBot::EVENT_BOTS => sub {} ,
		$SlackBot::EVENT_REPLY_TO => sub {},

		hello => sub {
			console "Slack: connection ready.";
		},

		reconnect_url => sub {},
		presence_change => sub {},
		user_typing => sub {},
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
					console "missing user? %s",Data::Dump::dump($message);
					$message->{user}='?';
				}

				return if defined $slack_bot_id and $slack_bot_id eq $message->{user};

				my $member;
				if( $message->{user_profile} ){
					$member = $slack_user_map->{ $message->{user} } = $message->{user_profile};
				}else{
					$member = $slack_user_map->{ $message->{user} };
				}
				my $from =  (not defined $member ) ? $message->{user} : $member->{name};
				

				if( defined $message->{channel} 
				and defined $slack_channel_id
				and $message->{channel} ne $slack_channel_id 
				){
					console "destination not matcn. %s",Data::Dump::dump($message);
					return;
				}

				if( $message->{subtype} eq "channel_join" ){
					#
				}elsif( $message->{subtype} eq "channel_leave" ){
					#
				}else{
					console "unknown subtype? %s",Data::Dump::dump($message) if $message->{subtype};
				}
				
				my $from =  (not defined $member ) ? $message->{user} : $member->{name};
				my $msg = $message->{text};
				if( defined $message->{message} and not defined $msg ){
					$msg = $message->{message}{text};
				}
				if( defined $msg ){
					my @lines = split /[\x0d\x0a]+/,decode_slack_message($msg);
					for my $line (@lines){
						next if not dnl $line;
						relay_to_irc( "<$from> $line");
					}
				}
			};
			$@ and console $@;
		}
	);
	$slack_bot->start;
}


=cut
