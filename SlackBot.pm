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

# 非同期処理でエラーがあった場合に発生するイベント。引数はエラーメッセージ
our $EVENT_ERROR : Constant( '<>error');

# ハンドラが登録されていないイベントのキャッチアップ
our $EVENT_CATCH_UP : Constant( '<>catch_up');

# 送信したメッセージに対するタイムスタンプが確定したら呼ばれる。引数はJSONオブジェクト
our $EVENT_REPLY_TO : Constant( '<>reply_to');

# typeのない未知のメッセージを受け取った
our $EVENT_UNKNOWN_MESSAGE : Constant( '<>unknown_message');

# rmt.startのレスポンスや各種Web APIのレスポンスが通知される
our $EVENT_SELF : Constant( '<>self');
our $EVENT_TEAM : Constant( '<>team');
our $EVENT_USERS : Constant( '<>users');
our $EVENT_CHANNELS : Constant( '<>channels');
our $EVENT_GROUPS : Constant( '<>groups');
our $EVENT_MPIMS : Constant( '<>mpims');
our $EVENT_IMS : Constant( '<>ims');
our $EVENT_BOTS : Constant( '<>bots' );


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
		last_event_received =>0,
		user_agent => "SlackBot.pm",
		@_,
	#	token	 => $token,
	}, $class;
}

sub is_active{
	my $self = shift;
	return $self->{busy_rtm_start} or $self->{busy_wss_connect} or $self->{conn};
}

sub is_ready{
	my $self = shift;
	return $self->{conn} and $self->{said_hello};
}

sub close {
	my ($self)=@_;
	eval{
		$self->{conn}->close
	};
}

sub user_agent{
	my $self = shift;

	@_ and $self->{user_agent} = $_[0] // "SlackBot.pm";

	$self->{user_agent};
}

sub start {
	my($self) = @_;

	$self->{busy_rtm_start} = 1;
	$self->{busy_wss_connect} = 0;
	$self->{said_hello} = 0;

	http_get $URL_RTM_START .'?token='. $self->{token}
	, headers => {
		'User-Agent',$self->{user_agent}
	}
	, sub {
		my($data,$headers)=@_;

		$self->{busy_rtm_start} = 0;

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
				$self->{busy_wss_connect} = 0;

				my $conn = $self->{conn} = eval{ shift->recv };
				$@ and return $self->_fire( $EVENT_ERROR, "WebSocket error. $@");

				$self->{message_id_seed} = 1; # 送信メッセージのIDはコネクションごとにユニーク

				$self->{pinger} = AnyEvent->timer(
					after	 => 60,
					interval => $self->{ping_interval},
					cb		 => sub { $self->ping },
				);

				$conn->on(finish => sub { 
					my( $conn ) = @_;

					# Cancel the pinger
					undef $self->{pinger};
					undef $self->{conn};

					$self->_fire('finish');
				});

				$conn->on(each_message => sub {
					my ($conn, $raw) = @_;
					
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


sub metadata { shift->{metadata} // {} }

sub quiet {
	my $self = shift;
	if (@_) {
		$self->{quiet} = shift;
	}
	return $self->{quiet} // '';
}

sub on {
	my ($self, $type, $cb) = @_;
	$self->{registry}{$type} = $cb;
}


sub off {
	my ($self, $type) = @_;
	delete $self->{registry}{$type};
}

sub _fire {
	my ($self, $type, @args) = @_;
	my $cb = $self->{registry}{$type};
	$cb or $cb = $self->{registry}{$EVENT_CATCH_UP};
	$cb and $cb->($self, $type, @args);
}

sub _update_info{
	my($self,$key,$data,$event_name)=@_;
	return if not defined $data;

	$self->{metadata}{$key} = $data;
	$self->_fire( $event_name ,$data );
}

sub send {
	my ($self, $msg) = @_;
	my $msg_id;
	eval{
		if( not $self->{conn} ){
			warn "Cannot send because the Slack connection is not started.";
		}elsif( not $self->{said_hello} ){
			warn "Cannot send because Slack has not yet said hello.";
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
sub _call_list_api{
	my($self,$url,$key,$key2,$event_type,$cb_error)=@_;

	$cb_error //= sub{ };

	http_get "$url?token=$self->{token}", sub {
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

