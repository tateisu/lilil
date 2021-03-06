#!/usr/bin/perl --
use utf8;
use strict;
use warnings;

# perlバージョン
use v5.22;

# 外部依存関係
use AnyEvent;
use Time::HiRes qw(time);
use Scalar::Util qw( reftype );
use Data::Dump qw(dump);

# スクリプトのあるフォルダを依存関係に追加する
use FindBin 1.51 qw( $RealBin );
use lib $RealBin;

# アプリ内モジュール
use Logger;
use ConfigUtil;
use SlackUtil;
use SlackBot;
use IRCUtil;
use IRCBot;
use MatrixBot;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

# 設定ファイル
my $config_file = shift // 'config.pl';

my $logger = Logger->new();
$logger->prefix("");

our $config;

my @slack_bots;
my @irc_bots;
my @matrix_bots;
my @relay_rules;

my %slack_bot_map;
my %irc_bot_map;
my %matrix_bot_map;


###########################################################

# returns error-string or undef.
sub fanOutIrc {
	my($relay,$outRoom,$msg)=@_;

	# IRCだけニックネーム区切りを < >に変える
	# 先頭に (notice) やら (action) やら入るかもしれない
	$msg =~ s/`([^`]+)`/<$1>/;
	
	my $bot = $irc_bot_map{ $outRoom->{connName} };
	return "fanOutIrc: missing conn '$outRoom->{connName}'" if not $bot;
	return "I[$outRoom->{connName}]not ready to relay." if not $bot->is_ready;

	my $out_channel = $bot->find_channel_by_name( $outRoom->{irc_channel_lc} );
	return "I[$outRoom->{connName}]unknown channel '$outRoom->{irc_channel}'" if not $out_channel;

	my $relay_command = $relay->{use_notice}? 'NOTICE':'PRIVMSG';
	$logger->i("I[%s]=>%s %s",$outRoom->{connName}, $outRoom->{roomName},$msg);
	$bot->send($relay_command,$out_channel->{channel_raw},$bot->{encode}($msg));
	return undef;
};

# returns error-string or undef.
sub fanOutMatrix {
	my($relay,$outRoom,$msg)=@_;
	
	my $bot = $matrix_bot_map{ $outRoom->{connName} };
	return "fanOutIrc: missing conn '$outRoom->{connName}'" if not $bot;
	return "M[$outRoom->{connName}]not ready to relay." if not $bot->is_ready;

	my $roomId = $outRoom->{roomName};
	$logger->i("M[%s]=>%s %s",$outRoom->{connName},$roomId,$msg);
	$bot->send($roomId,$msg);
	return undef;
};

# returns error-string or undef.
sub fanOutSlack  {
	my($relay,$outRoom,$msg)=@_;

	my $bot = $slack_bot_map{ $outRoom->{connName} };
	return "unknown slack_conn '$outRoom->{connName}'" if not $bot;
	return "S[$outRoom->{connName}]not ready to relay." if not $bot->is_ready;

	my $slack_channel = $bot->find_channel_by_name($outRoom->{roomName});
	return "S[$outRoom->{connName}]unknown slack_channel '$outRoom->{roomName}'" if not $slack_channel;

	$logger->i("S[%s]=>%s %s",$outRoom->{connName},$outRoom->{roomName},$msg);
	$bot->send_message( $slack_channel->{id},$msg);
	return undef;
};

sub fanOut{
	my($msg,$check)=@_;

	my @errors;
	my $count_fanout = 0;
	
	for my $relay (@relay_rules){
		next if $relay->{disabled};

		my $inRoom = &$check($relay);
		if( not reftype $inRoom){
			push @errors,$inRoom;
			next;
		}

		for my $outRoom (@{$relay->{outRooms}}){
			next if $inRoom->{key} eq $outRoom->{key};
			my $fanOutX = $outRoom->{fanOut};
			my $error = &$fanOutX($relay,$outRoom,$msg);
			if($error){
				push @errors,$error;
				next;
			}
			++$count_fanout;
		}
	}

	if( not $count_fanout ){
		for(@errors){
			$logger->d("fanout failed. $_");
		}
	}
}


sub cb_slack_relay{
	my( $bot,$channel_id,$msg) = @_;
	
	# find channel name by id
	my $channel = $bot->find_channel_by_id( $channel_id );
	return $logger->w("S[%s]unknown slack channel. id=%s",$bot->{config}{name},$channel_id) if not $channel;

	my $channelName = "\#$channel->{name}";

	fanOut($msg,sub{
		my($relay)=@_;
		my($inRoom) = grep{ $_->{type} eq "slack" and $_->{connName} eq $bot->{config}{name} and $_->{roomName} eq $channelName} @{$relay->{inRooms}};
		return "can't find roomSpec from inRooms. slack,$bot->{config}{name},$channelName" if not $inRoom;
		return $inRoom;
	});
}

sub cb_matrix_relay{
	my($bot, $roomId, $sender, $msg )=@_;

	fanOut("`$sender` $msg",sub{
		my($relay)=@_;
		my($inRoom) = grep{ $_->{type} eq "matrix" and $_->{connName} eq $bot->{config}{name} and $_->{roomName} eq $roomId} @{$relay->{inRooms}};
		return "can't find roomSpec from inRooms. matrix,$bot->{config}{name},$roomId" if not $inRoom;
		return $inRoom;
	});
}

sub cb_irc_relay{
	my($bot, $from_nick,$command,$channel_raw, $channel, $msg )=@_;

	my $channel_lc = IRCUtil::lc_irc( $channel );

	my $is_notice = ($command =~ /notice/i);

	my $is_action = 0;
	if( $msg =~ s/\A\x01ACTION\s+(.+)\x01\z/$1/ ){
		$is_action = 1;
	}

	$msg = "`$from_nick` $msg";
	$msg = "(action) $msg" if $is_action;
	$msg = "(notice) $msg" if $is_notice;

	fanOut($msg,sub{
		my($relay)=@_;
		my($inRoom) = grep{ $_->{type} eq "irc" and $_->{connName} eq $bot->{config}{name} and $_->{irc_channel_lc} eq $channel_lc} @{$relay->{inRooms}};
		return "can't find roomSpec from inRooms. irc,$bot->{config}{name},$channel_lc" if not $inRoom;
		return "NOTICEをリレーしない設定なので無視します" if $is_notice and $relay->{dont_relay_notice};
		return $inRoom;
	});
}

sub cb_status{
	my @r;
	for( @slack_bots ){
		push @r,sprintf("Slack[%s]:%s",$_->{config}{name},$_->status);
	}
	for( @irc_bots ){
		push @r,sprintf("IRC[%s]:%s",$_->{config}{name},$_->status);
	}
	for( @matrix_bots ){
		push @r,sprintf("Matrix[%s]:%s",$_->{config}{name},$_->status);
	}
	@r;
}

#########################################################################

my %relay_keywords = ConfigUtil::parse_config_keywords(qw(

	input:ao
	in:ao
	out:ao

	disabled:b
	dont_relay_notice:b
	use_notice:b
));

sub check_relay_config{
	return ConfigUtil::check_config_keywords(\%relay_keywords,@_);
}

# returns string if error, else return roomSpec.
sub parseRoomSpec{
	my($type,$connName,$roomName) = @_;

	return "parseRoomSpec: missing type,connName,roomName @_" if !( $type and $connName and $roomName );

	my $spec = { type=>$type, connName =>$connName, roomName=>$roomName};

	if( $type eq "irc"){
		$spec->{fanOut} = \&fanOutIrc;
		my($conn) = grep { $_->{name} eq $connName } @{ $config->{irc_connections} };
		return "parseRoomSpec: $type '$connName' is not found." if not $conn;
		return "parseRoomSpec: $type '$connName' is disabled." if $conn->{disabled};

		my $fixedName = IRCUtil::fix_channel_name( $roomName ,1);
		$spec->{irc_channel} = $fixedName;
		$spec->{irc_channel_lc} = IRCUtil::lc_irc( $fixedName );

		# 自動で補う
		if( not grep{ IRCUtil::lc_irc( IRCUtil::fix_channel_name($_,1) ) eq $spec->{irc_channel_lc}} @{ $conn->{auto_join} } ){
			push @{ $conn->{auto_join} }, $fixedName;
		}

	}elsif( $type eq 'slack'){
		$spec->{fanOut} = \&fanOutSlack;
		my($conn) = grep { $_->{name} eq $connName } @{ $config->{slack_connections} };
		return "parseRoomSpec: $type '$connName' is not found." if not $conn;
		return "parseRoomSpec: $type '$connName' is disabled." if $conn->{disabled};

	}elsif( $type eq 'matrix'){
		$spec->{fanOut} = \&fanOutMatrix;
		my($conn) = grep { $_->{name} eq $connName } @{ $config->{matrix_connections} };
		return "parseRoomSpec: $type '$connName' is not found." if not $conn;
		return "parseRoomSpec: $type '$connName' is disabled." if $conn->{disabled};

	}else{
		return "unknown type '$type'";
	}

	$spec->{key} = join ',',@{$spec}{qw(type connName roomName)};
	return $spec;
}

# returns string if error, else return array of roomSpec.
sub parseRoomSpecList{
	my($relay,$srcListName)=@_;
	my @dst;
	my $srcList = $relay->{$srcListName};
	if($srcList){
		return "$srcListName is not array." if 'ARRAY' ne reftype $srcList;
		for(@$srcList){
			my $spec = parseRoomSpec(@$_);
			return $spec if not reftype $spec;
			push @dst,$spec;
		}
	}
	return \@dst;
}

# returns string if error, else return undef.
sub hasDuplidateRoomSpec{
	my($list)=@_;
	my %used;
	for my $spec (@$list){
		return "duplicate room spec: $spec->{key}" if $used{ $spec->{key}}++;
	}
	return undef;
}

# returns string if error, else return undef.
sub checkRelay{
	my($relay)=@_;

	# 無効なら検証しない
	if( $relay->{disabled}){
		$relay->{inRooms} = [];
		$relay->{outRooms} = [];
		return undef;
	}

	my $in = parseRoomSpecList($relay,"in");
	return $in if not reftype $in;

	my $out = parseRoomSpecList($relay,"out");
	return $out if not reftype $out;

	my $inout = parseRoomSpecList($relay,"inout");
	return $inout if not reftype $inout;

	my @in = ( @$inout,@$in);
	my @out = ( @$inout,@$out);

	return "empty inRooms." if not @in;
	return "empty outRooms." if not @out;

	my $error = hasDuplidateRoomSpec(\@in);
	return $error if $error;	

	$error = hasDuplidateRoomSpec(\@out);
	return $error if $error;	

	$relay->{inRooms} = \@in;
	$relay->{outRooms} = \@out;

	return undef;
}

sub reload{
	my($allow_die)=@_;

	$logger->d("loading $config_file ...");
	$config = do $config_file;
	$@ and die "$config_file : $@\n";
	
	my $valid = 1;

	my $slackConnections = $config->{slack_connections};
	if( $slackConnections ){
		if( 'ARRAY' ne reftype $slackConnections ){
			$logger->e(" 'slack_connections' is not array reference.");
			$valid = 0;
		}else{
			my %name;
			for( @$slackConnections ){
				if( not SlackBot::check_config( $_, $logger ) ){
					$logger->e("slack_connections[$_->{name}] has error.");
					$valid = 0;
				}
				if( $name{ $_->{name} }++ ){
					$logger->e("slack_connections[$_->{name}] is duplicated.");
					$valid = 0;
				}
			}
		}
	}

	my $ircConnections = $config->{irc_connections};
	if( $ircConnections ){
		if( 'ARRAY' ne reftype $ircConnections ){
			$logger->e(" 'irc_connections' is not array reference.");
			$valid = 0;
		}else{
			my %name;
			for( @$ircConnections ){
				if( not IRCBot::check_config( $_, $logger ) ){
					$logger->e("irc_connections[$_->{name}] has error.");
					$valid = 0;
				}
				if( $name{ $_->{name} }++ ){
					$logger->e("irc_connections[$_->{name}] is duplicated.");
					$valid = 0;
				}
			}
		}
	}

	my $matrixConnections = $config->{matrix_connections};
	if( $matrixConnections ){
		if( 'ARRAY' ne reftype $matrixConnections ){
			$logger->e(" 'irc_connections' is not array reference.");
			$valid = 0;
		}else{
			my %name;
			for( @$matrixConnections ){
				if( not MatrixBot::check_config( $_, $logger ) ){
					$logger->e("matrix_connections[$_->{name}] has error.");
					$valid = 0;
				}
				if( $name{ $_->{name} }++ ){
					$logger->e("matrix_connections[$_->{name}] is duplicated.");
					$valid = 0;
				}
			}
		}
	}

	if( 'ARRAY' ne reftype $config->{relay_rules} ){
		$logger->e(" 'relay_rules' is not array reference.");
		$valid = 0;
	}else{
		my $n = 0;
		for my $relay ( @{ $config->{relay_rules} } ){
			my $error = checkRelay($relay);
			if($error){
				$logger->e("relay_rules[$n]: $error");
				$valid = 0;
			}
			++$n;
		}
	}

	if(!$valid){
		if($allow_die){
			$logger->e("configuration has error. exit.");
			exit 1;
		}else{
			$logger->e("configuration has error. reload cancelled.");
			return;
		}
	}

	my $debug_level = $logger->debug_level( $config->{debug_level} );
	$logger->i("debug_level=%s",Logger::string_debug_level( $debug_level ));

	####

	for my $bot ( @slack_bots ){
		$bot->dispose;
	}

	undef @slack_bots;
	undef %slack_bot_map;
	for my $c ( @{ $config->{slack_connections} } ){
		next if $c->{disabled};
		my $bot = new SlackBot(
			cb_relay => \&cb_slack_relay,
			cb_status=> \&cb_status,
		);
		$bot->config( $c );
		$bot->{logger}->debug_level($debug_level);
		push @slack_bots,$bot;
		$slack_bot_map{ $c->{name} } = $bot;
	}

	####
	
	for my $bot ( @irc_bots ){
		$bot->dispose;
	}
	undef @irc_bots;
	undef %irc_bot_map;
	for my $c ( @{ $config->{irc_connections} } ){
		next if $c->{disabled};
		my $bot = new IRCBot(
			cb_relay => \&cb_irc_relay,
			cb_status=> \&cb_status,
		);
		$bot->config( $c );
		$bot->{logger}->debug_level($debug_level);
		push @irc_bots,$bot;
		$irc_bot_map{ $c->{name} } = $bot;
	}

	####
	
	for my $bot ( @matrix_bots ){
		$bot->dispose;
	}
	undef @matrix_bots;
	undef %matrix_bot_map;
	for my $c ( @{ $config->{matrix_connections} } ){
		next if $c->{disabled};
		my $bot = new MatrixBot(
			cb_relay => \&cb_matrix_relay,
			cb_status=> \&cb_status,
		);
		$bot->config( $c );
		$bot->{logger}->debug_level($debug_level);
		push @matrix_bots,$bot;
		$matrix_bot_map{ $c->{name} } = $bot;
	}

	####

	@relay_rules = @{ $config->{relay_rules} };
}

###########################################################
# タイマー

my $timer = AnyEvent->timer(
	interval => 1 , cb => sub {
		## $logger->d("timer.");

		for my $bot ( @slack_bots ){
			$bot->on_timer;
		}

		for my $bot ( @irc_bots ){
			$bot->on_timer;
		}
		for my $bot ( @matrix_bots ){
			$bot->on_timer;
		}
	}
);

###########################################################
# シグナルハンドラ


my $c = AnyEvent->condvar;

my $signal_watcher_int = AnyEvent->signal(signal => 'INT',cb=>sub {
	$logger->i("signal INT");
	$c->broadcast;
});

my $signal_watcher_term = AnyEvent->signal(signal => 'TERM',cb=>sub {
	$logger->i("signal TERM");
	$c->broadcast;
});

my $signal_watcher_hup = AnyEvent->signal(signal => 'HUP',cb=>sub {
	$logger->i("signal HUP");
	reload();
});

###########################################################

reload('allow_die');

if( $config->{pid_file} ){
	$logger->i("write pid file to $config->{pid_file}");
	open(my $fh,">",$config->{pid_file}) or die "$config->{pid_file} $!";
	print $fh "$$";
	close($fh) or die "$config->{pid_file} $!";
}

$logger->i("loop start.");
$c->wait;
$logger->i("loop end.");
exit 0;
