package IRCConnection;
$IRCConnection::VERSION = '0.161009'; # YYMMDD

use v5.14;
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Attribute::Constant;

sub new {
	my $class = shift;
	
	return bless {
		registry => {},
		heap => {},
		last_read => time,
		
		@_,
	},$class;
}

sub dispose{
	my $self = shift;

	$self->{is_disposed} = 1;
	$self->{registry} = {};

	$self->disconnect(@_);
}

######################################################################

# ハンドラが登録されていないイベントのキャッチアップ。引数は実際のイベントタイプによって異なる
our $EVENT_CATCH_UP : Constant( '<>catch_up');

# 非同期処理でエラーがあった場合に発生するイベント。引数はエラーメッセージ
our $EVENT_ERROR : Constant( '<>error');

our $EVENT_CONNECT : Constant( '<>connect'); # ソケット接続が確立された。認証は行われていない
our $EVENT_DISCONNECT : Constant( '<>disconnect'); # 接続が完了した

our $EVENT_TX_READY : Constant( '<>tx_ready'); # AnyEvent::Handle のon_drain が発生した


# イベントハンドラの登録
sub on {
	my $self = shift;
	my $size = 0+@_;
	for( my $i=0 ; $i<$size-1 ; $i+=2 ){
		my $type = $_[$i];
		my $cb = $_[$i+1];
		if( ref $type ){
			for(@$type){
				$self->{registry}{$_} = $cb;
			}
		}else{
			$self->{registry}{$type} = $cb;
		}
	}
}

# イベントハンドラの除去
sub off {
	my $self = shift;
	for(@_){
		delete $self->{registry}{$_};
	}
}

sub _fire{
	my($self,$type,@args)=@_;
	eval{
		my $cb = $self->{registry}{$type};
		$cb or $cb = $self->{registry}{$EVENT_CATCH_UP};
		$cb and $cb->($self,$type,@args);
	};
	$@ and warn "IRCConnection: event handler died. type=$type, error=$@\n";
}

######################################################################

sub is_active {
	my ($self) = @_;
	return(  $self->{socket} or $self->{busy_connect} );
}

sub is_ready {
	my $self = shift;
	return( $self->{socket} and $self->{authorized} );
}

sub last_read{ shift->{last_read} }

sub enable_ssl {
	my ($self) = @_;
	$self->{enable_ssl} = 1;
}


sub disconnect {
	my ($self, $reason) = @_;

	delete $self->{con_guard};
	delete $self->{socket};

	$self->_fire($EVENT_DISCONNECT,$reason);
}

sub connect {
	my( $self, $host, $port, $prepare_cb ) = @_;

	$self->{host} = $host;
	$self->{port} = $port;

	$self->{authorized} = 0;
	$self->{busy_connect} = 1;
	$self->{con_guard} = tcp_connect $host, $port
	,sub {
		my($fh)=@_;
		$self->{busy_connect} = 0;
		eval{
			$fh or return $self->_fire( $EVENT_ERROR,"connection failed. $!");

			$self->{socket} = AnyEvent::Handle->new (
				
				fh => $fh
				
				,($self->{enable_ssl} ? (tls => 'connect') : ())
				
				,on_eof => sub{ $self->disconnect( "end of stream." ) }
				,on_error => sub{ $self->disconnect( "connection lost. $!") }
				
				,on_drain => sub{ $self->_fire($EVENT_TX_READY) }
				
				,on_read => sub {
					my ($hdl) = @_;
					# \015* for some broken servers, which might have an extra carriage return in their MOTD.
					$hdl->push_read (line => qr{\015*\012}, sub {
						my(undef,$line)=@_;
						$self->{last_read} = time;

						#d# warn "LINE:[" . $line . "][".length ($line)."]";

						my $m = parse_irc_msg ($line);
						#d# warn "MESSAGE{$m->{params}->[-1]}[".(length $m->{params}->[-1])."]\n";
						#d# warn "HEX:" . join ('', map { sprintf "%2.2x", ord ($_) } split //, $line)
						#d#     . "\n";
						
						$self->{authorized} = 1 if $m->{command} eq '001';

					#	$self->_fire(read => $m);
					#	$self->_fire('irc_*' => $m);
						$self->_fire('irc_' . (lc $m->{command}), $m);
					});
				}
			);
			$self->_fire($EVENT_CONNECT);
		};
		$@ and return $self->_fire( $EVENT_ERROR,"error. $@");
	}
	,(defined $prepare_cb ? (ref $prepare_cb ? $prepare_cb : sub { $prepare_cb }) : ());
}

sub parse_irc_msg {
	my ($msg) = @_;

	$msg =~ s/^(?::([^ ]+)[ ])?([A-Za-z]+|\d{3})// or return undef;

	my %msg;
	($msg{prefix}, $msg{command}, $msg{params}) = ($1, $2, []);

	my $cnt = 0;
	while ($msg =~ s/^[ ]([^ :\015\012\0][^ \015\012\0]*)//) {
		push @{$msg{params}}, $1 if defined $1;
		last if ++$cnt > 13;
	}
	if( $cnt == 14 ){
		if ($msg =~ s/^[ ]:?([^\015\012\0]*)//) {
			push @{$msg{params}}, $1 if defined $1;
		}
	} else {
		if ($msg =~ s/^[ ]:([^\015\012\0]*)//) {
			push @{$msg{params}}, $1 if defined $1;
		}
	}

	\%msg
}


sub send{
	my ($self, @args) = @_;
	return unless $self->{socket};
	my $trail = @args >= 2 ? ' :'.pop @args : '';
	$self->{socket}->push_write ( join(' ',@args).$trail."\015\012" );
}

1;
__END__

TODO
- Flood Protection
- bind source
