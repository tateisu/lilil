package SlackBot;
$SlackBot::VERSION = '0.160928'; # YYMMDD

use v5.14;
use strict;
use warnings;

use JSON;
use Data::Dump;
use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;
use AnyEvent::HTTP;

my $START_URL = 'https://slack.com/api/rtm.start';

sub new {
	my $class = shift;

	return bless {
		client	 => AnyEvent::WebSocket::Client->new,
		registry => {},
		ping_interval => 60,
		cb_error => sub{ },
		cb_warn => sub{ },
		@_,
	#	token	 => $token,
	}, $class;
}

sub said_hello { shift->{said_hello} // '' }

sub finished { shift->{finished} // '' }

sub close {
	eval{
		shift->{conn}->close
	};
}

sub start {
	my($self) = @_;

	$self->{said_hello} = 0;
	$self->{started} = 0;
	$self->{finished} = 0;
	$self->{metadata} = undef;

	use vars qw( $VERSION );
	$VERSION //= '*-devel';

	http_get $START_URL .'?token='. $self->{token}, sub {
		my($data,$headers)=@_;

		if( not defined $data ){
			$self->{cb_error}( "server error. ".$headers->{Status}." ".$headers->{Reason} );
			return;
		}
		
		my $json = eval{ decode_json($data) };
		if($@){
			$self->{cb_error}( "json parse error. ".$@ );
			return;
		}elsif( not $json->{ok} ){
			$self->{cb_error}( "response error. ".$json->{error} );
			return;
		}

		$self->{metadata} = $json;

		eval{
			$self->{client}->connect($self->{metadata}{url})->cb(sub {

				# get connection object
				my $conn = eval{ shift->recv };
				if($@){
					$self->{cb_error}( "WebSocket Connnetion error. ".$@ );
					return;
				}
				
				$self->{started}++;
				$self->{id} = 1;
				$self->{conn} = $conn;

				$self->{pinger} = AnyEvent->timer(
					after	 => 60,
					interval => $self->{ping_interval},
					cb		 => sub { $self->ping },
				);
				$conn->on(finish => sub { 
					my( $conn ) = @_;
					# Cancel the pinger
					undef $self->{pinger};
					$self->{finished}++;
					$self->_do('finish');
				});
				$conn->on(each_message => sub {
					my ($conn, $raw) = @_;
					# parse json
					my $json = eval{ decode_json($raw->body) };
					if( $@ ){
						$self->{cb_error}( "incoming message parse error. ".$@ );
						return;
					}
					if( not $json->{type} ){
						warn Data::Dump::dump($json),"\n";
					}else{
						# 
						$self->{said_hello}++ if $json->{type} eq 'hello';
						$self->_do($json->{type}, $json);
						# type is hello,error,pong, message
					}

				});
			});
		};
		if($@){
			$self->{cb_error}( "WebSocket connection error. ".$@ );
			return;
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

sub _do {
	my ($self, $type, @args) = @_;
	my $cb = $self->{registry}{$type};
	$cb and $cb->($self, @args);
}

sub send {
	my ($self, $msg) = @_;

	eval{
		if( not $self->{started} ){
			warn "Cannot send because the Slack connection is not started.";
		}elsif( not $self->{said_hello} ){
			warn "Cannot send because Slack has not yet said hello.";
		}elsif( $self->{finished} ){
			warn "Cannot send because the connection is finished";
		}else{
			$msg->{id} = $self->{id}++;
			my $json = encode_json($msg);
			$self->{conn}->send($json);
		}
	};
	$@ and warn $@;
}

sub ping {
	my ($self, $msg) = @_;
	$self->send({  %{ $msg // {} } ,type => 'ping' } );
}

