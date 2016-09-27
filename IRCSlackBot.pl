#!/usr/bin/perl --
use utf8;
use strict;
use warnings;
use JIS4IRC;
use JSON;
use Carp;
use Data::Dump;
use Furl;
use Encode;
use Encode::Guess;
use Time::HiRes qw(time);

require POE::Wheel::Run;
require POE::Component::Client::DNS;
require POE::Component::IRC;
use POE qw(Component::IRC);
use AnyEvent;
use AnyEvent::SlackRTM;

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my $debug = 0;

my $slack_bot_token;
{
	my $fname = "slack-bot-token.txt";
	open(my $fh,"<",$fname) or die "$fname $!";
	$slack_bot_token = <$fh>;
	close($fh) or die "$fname $!";
	$slack_bot_token or die "$fname: not contains slack bot api token";
	$slack_bot_token =~ s/[\x00-\x1f]+//g;
	$slack_bot_token or die "$fname: not contains slack bot api token";
}


# 接続の設定
my @BotSpec = (
	{
		# ログに出る名前
		Name => "wide",
		
		# サーバ指定。
		# FIXME: 複数サーバに交互に接続する機能があるといいのかも。今回はいらないが。
		ServerSpec => {
			Nick	 => 'write bot nickname here',
			Server	 => 'irc.livedoor.ne.jp', # サーバ名
			Port	 => '6667',# ポート番号,
			Username => 'write username here',
			Ircname  => 'write summary,etc here',
			Bitmode => 8, # 8は+i相当
			msg_length => 2048,
		},
		
		# MOTDを受け取った後にjoinするチャネル
		JoinChannel =>[
			'write channel name here',
		],
		
		# (内部)再接続時にjoinするチャネル。これはinviteされたチャネルを含むはずだ
		CurrentChannel => {},
		
		encode => sub{ JIS4IRC::fromEUCJP( $eucjp->encode($_[0])); },
		decode => sub{ $eucjp->decode( JIS4IRC::toEUCJP(  $_[0])); },
		
		AutoOpRegEx  => [
#			qr/^tate.+\Q!~tATE-0dBPg@\E/i,
		],
		
		SkipURLWithComment => 0,
	}
);

###################################################
# ユーティリティ

sub console($;$$$$$$$$$$$$$$$$){
	printf STDERR @_;
	print STDERR "\n";
}

our $TAG = '$$TAG$$';

##########################################################################
# Slack bot on AnyEvent

my $slack_channel_id = "write channel id here";
my $slack_rtm;
my $keep_alive;

sub slack_start{
	$slack_rtm = AnyEvent::SlackRTM->new($slack_bot_token);

	$slack_rtm->on(
		'hello' => sub {
			print "Slack Connection ready.\n";
			$keep_alive = AnyEvent->timer(
				interval => 60
				, cb => sub {
					print "Ping\n";
					$slack_rtm->ping;
				}
			);
		}
	);

	$slack_rtm->on(
		'message' => sub {
			my ($rtm, $message) = @_;
			warn Data::Dump::dump($message);
			relay_to_irc( $message->{user},$message->{text});
		}
	);

	$slack_rtm->on(
		'finish' => sub {
			print "Slack Connection finished.\n";
			undef $slack_rtm;
		}
	);
	$slack_rtm->start;
}

# text は UTF8フラグつきの文字列であること
sub relay_to_slack{
	my($from,$text)=@_;
	$from =~ s/!.*//;
	eval{
		$slack_rtm->send(
			{
				type => 'message'
				,channel => $slack_channel_id
				,text => "<$from> $text"
			}
		);
	};
	$@ and warn $@;
}

my $user_map;
my $user_map_update;
my $URL_USER_LIST = "https://slack.com/api/users.list";
my $furl = Furl->new( agent => "IRCSlackBot", );

sub update_slack_cache {
	my($user_id) = @_;
	
	my $now = time;
	if( $user_map && $now - $user_map_update < 5*60 ){
		# キャッシュを更新しない
	}elsif( not $user_map or not $user_map->{$user_id} ){
		$user_map_update = $now;

		# キャッシュを更新する
		my $res = $furl->get($URL_USER_LIST . '?token=' . $slack_bot_token);
		my $json = decode_json($res->content);
	    if( not $json->{ok} ){
		    croak "unable to get user list, Slack returned an error: $json->{error}"
		}else{
		    $user_map = {};
		    for my $member ( @{ $json->{members} } ){
				$user_map->{ $member->{id} } = $member;
			}
		}
	}
}
update_slack_cache("");


###########################################################

my $relay_irc_bot ;
my $relay_irc_channel;

sub relay_to_irc{
	my($user_id,$text)=@_;
	
	warn 1;
	
	my $from;
	{
		eval{
			update_slack_cache($user_id);
		};
		$@ and warn $@;
		my $member = (not defined $user_map )? undef : $user_map->{$user_id};
		$from =  (not defined $member ) ? $user_id : $member->{name};
	}
	
	warn 2;

	# text は UTF8フラグつきの文字列であること
	eval{
		my $msg = "<$from>$text";
		console "SlackToIRC: $msg => $relay_irc_channel";
		$relay_irc_bot->{irc}->yield( notice => $relay_irc_channel , $relay_irc_bot->{encode}($msg) );
	};
	$@ and warn $@;

	warn 3;
}

############################################################

###################################################
# 子プロセスの管理

my %child_map;

sub handle_url($$$$$){
	my($kernel, $heap,$bot,$channel,$url)=@_;

	sweep();
	console(" child_map count=". (0+keys(%child_map)) );
	
	if( keys(%child_map) >= 100 ){
		console "too many info. ignore url..";
		return;
	}

	my $task = POE::Wheel::Run->new(
		Program 	=> [ "/usr/bin/perl", "get_title.pl", $url],
		StdoutFilter => POE::Filter::Line->new(),
		StdoutEvent => "child_stdout",
		StderrEvent => "child_stderr",
		ErrorEvent	=> "child_error",
		CloseEvent	=> "child_close",
	);
	if( not $task ){
		console "ERROR: cannot create child process.";
		return;
	}else{
		$kernel->sig_child($task->PID, "child_signal");
		$task->shutdown_stdin();
	}
	$child_map{ $task->ID } = { 
		 task=>$task
		,bot=>$bot
		,channel=>$channel
		,url=>$url
		,time_start=> time
		,buf_stdout=>"" 
		,buf_stderr=>"" 
	};
}

sub child_stdout {
	my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
	my $info = $child_map{$wheel_id};
#	console "child_stdout length=%s",length($input);
	$info and $info->{buf_stdout} .= $input;
}
sub child_stderr {
	my ($heap, $input, $wheel_id) = @_[HEAP, ARG0, ARG1];
	my $info = $child_map{$wheel_id};
#	console "child_stderr length=%s",length($input);
	$info and $info->{buf_stderr} .= $input;
}
sub child_close{
	my ($heap, $wheel_id) = @_[HEAP, ARG0];
	my $info = $child_map{$wheel_id};
	console "child_close";
	delete $child_map{$wheel_id};
	task_close($info);
}
sub child_error{
	my ($heap, $operation, $errnum, $errstr, $wheel_id) = @_[HEAP,ARG0..ARG3];
	my $info = $child_map{$wheel_id};
	if( $operation eq "read" and !$errnum ){
		# console "child_error: remote end closed";
	}else{
		console "child_error %s %s %s",$operation,$errnum, $errstr;
	}
	delete $child_map{$wheel_id};
	task_close($info);
}
sub child_signal {
	my( $heap, $sig, $pid, $exit_val, $details ) = @_[ HEAP, ARG0..ARG3 ];
#	console "child_signal sig=%s pid=%s",$sig,$pid;
}

sub task_close{
	my($info)=@_;
	$info or return;

	my $sv = $utf8->decode($info->{buf_stderr});
	if( length($sv) > 0 ){
		console "%s %s",$sv,$info->{url};
	}
	#
	$sv = $utf8->decode($info->{buf_stdout});
	if( length($sv) > 0 ){
		my $bot = $info->{bot};
		my $channel = $info->{channel};
		console "%s %s: TITLE: %s",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$sv;
		$sv = "【$sv 】";
# ツイッターなどでタイトル末尾にURLが入ると、LimeChatなどがURL終端の検出に失敗する。
# 仕方ないのでタイトル末尾と閉じカッコの間に半角空白を入れる
		$bot->{irc}->yield( notice => $channel , $bot->{encode}($sv) );
	}
}

sub sweep {
	my $now = time;
	my @wait_pid;
	for my $id ( keys %child_map ){
		my $info = $child_map{ $id };
		my $delta = $now - $info->{time_start};
		if( $delta > 300 ){
			console "kill expired child pid=%s",$info->{task}->PID;
			$info->{task}->kill;
			delete $child_map{ $_ };
		}else{
			push @wait_pid,$info->{task}->PID;
		}
	}
	@wait_pid and console "wait pid=\[%s]",join(',',@wait_pid);
}



###################################################
# public message の処理

my %schema_map = (
	"http" =>"http",
	 "ttp" =>"http",
	 "ttp" =>"http",
	  "tp" =>"http",
	   "p" =>"http",
	"https" =>"https",
	 "ttps" =>"https",
	 "ttps" =>"https",
	  "tps" =>"https",
	   "ps" =>"https",
);

sub handle_message($$$$$$){
	my( $kernel,$heap,$bot,$from,$channel,$msg) = @_;

	if( $channel =~ /\A[\!\#\&\+]/ and $msg =~ /\A\s*tateURL>exit\s*\z/ ){
		console "%s %s: exit required by (%s),said (%s)",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$from,$msg;
		$bot->{irc}->yield( part => $channel );
	}else{
		relay_to_slack($from,$msg);
	}
}


###################################################
# IRC接続の管理


POE::Session->create(
	inline_states => {
		_start	   => \&bot_start, # セッション開始
		bot_timer => \&bot_timer, # 定期的に実行
		
		irc_connected	 => \&on_connect, # 接続できた
		irc_disconnected => \&on_disconnect, # 接続終了
		connection_ping  => \&on_connection_ping,  # 再接続を行う
		# サーバ接続直後
		irc_001    => \&on_001,  # 自分のprefixを調べる
		irc_376    => \&on_motd, # end of MOTD
		irc_422    => \&on_motd, # no MOTD
		# チャンネルへの参加
		irc_join   => \&on_join,   # チャンネルに入った
		irc_kick   => \&on_kick,   # 蹴られた
		irc_invite => \&on_invite, # 呼ばれた
		# メッセージ処理
		irc_public => \&on_public,
		irc_msg => \&on_public,
		# 子プロセスのイベント
		child_stdout => \&child_stdout,
		child_stderr => \&child_stderr,
		child_error  => \&child_error,
		child_close  => \&child_close,
		child_signal => \&child_signal,
	},
);


sub fix_channel_name($$){
	my($channel,$short_safe_channel)=@_;
	# safe channel の長いprefix を除去する
	$short_safe_channel and $channel =~ s/^\!.{5}/!/;
	# 大文字小文字の統一
	$channel =~ tr/\[\]\\ABCDEFGHIJKLMNOPQRSTUVWXYZ/\{\}\|abcdefghijklmnopqrstuvwxyz/;
	#
	return $channel;
}


# セッション開始時に呼ばれる
sub bot_start {
	my $kernel	= $_[KERNEL];
	my $heap	= $_[HEAP];
	my $session = $_[SESSION];
	# IRCオブジェクトを登録して接続する
	console "register IRC component..";
	for my $bot ( @BotSpec ){
		$bot->{irc} = POE::Component::IRC->spawn();
		$bot->{irc}->{$TAG} = $bot;
		$bot->{irc}->yield( register => 'all' );
		# チャネル名を正規化しておく
		$bot->{JoinChannel} = {
			map{ (fix_channel_name($_,0),1) }
			@{$bot->{JoinChannel}}
		};
	}
	for my $bot ( @BotSpec ){
		bot_connect( $bot,$bot->{irc} );
	}
	# タイマー開始
	$kernel->delay( bot_timer => 60 );
}

sub bot_timer{
	my $kernel	= $_[KERNEL];
	my $heap	= $_[HEAP];
	my $session = $_[SESSION];
	# 次回のタイマー
	$kernel->delay( bot_timer => 60 );
	# 接続開始
	for my $bot( @BotSpec ){
		bot_connect( $bot );
	}
}

###############################
# 接続状態の管理

sub bot_connect($){
	my($bot)=@_;
	if( $bot->{irc}{connected} ){
		## console "%s: already connected. ",$bot->{Name};
	}else{
		console "%s: connecting..",$bot->{Name};
		$bot->{irc}->yield( connect => $bot->{ServerSpec} );
	}
}

sub on_connect {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: connected to %s. please wait authentication..",$bot->{Name},$_[ARG0];
	$_[KERNEL]->delay( connection_ping => 60, $bot);
}

sub on_disconnect {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: disconnected.",$bot->{Name};
}

sub on_connection_ping{
	my $bot = $_[ARG0];
	if( $bot->{irc}->connected() && $bot->{server_prefix} ){
		$bot->{irc}->yield( ping => $bot->{server_prefix} );
		$_[KERNEL]->delay( connection_ping => 60, $bot);
	}
	if( not $slack_rtm ){
		slack_start();
	}
}

###############################
# 接続直後の初期化

sub on_001 {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $line = $bot->{encode}($_[ARG1]);
	console "%s: 001 from=%s line=%s",$bot->{Name},$from,$line;
	# 自分のprefixを覚えておく
	$line =~ /(\S+\!\S+\@\S+)/ and $bot->{user_prefix} = $1;
	$bot->{server_prefix} = $from;
}

sub on_motd {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	console "%s: end of MOTD.",$bot->{Name};
	for my $channel (keys %{ $bot->{JoinChannel} } ){
		my $arg = $bot->{encode}( $channel );
		$bot->{irc}->yield( join => $arg );
	}
	for my $channel (keys %{ $bot->{CurrentChannel} } ){
		my $arg = $bot->{encode}( $channel );
		$bot->{irc}->yield( join => $arg );
	}
}

sub on_join {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $who =  $_[ARG0];
	my $channel =  fix_channel_name($bot->{decode}($_[ARG1]),1);

	if( $who ne $bot->{user_prefix} ){
		# 他人のjoin
		# auto-op check
		for my $re (@{ $bot->{AutoOpRegEx} }){
			if( $who =~ /$re/ ){
				$who =~ /^([^!]+)/;
				console "%s %s: +o to %s",$bot->{Name},$channel,$1;
				$bot->{irc}->yield( mode => $_[ARG1] , "+o",$1 );
				last;
			}
		}
		return;
	}else{
		console "%s %s: join %s",$bot->{Name},$channel,$who;
		$bot->{JoinChannel}{$channel} or $bot->{CurrentChannel}{$channel}=1;
		
		$relay_irc_bot = $bot;
		$relay_irc_channel = $_[ARG1];

	}
}

sub lc_irc($){
	my($s)=@_;
	$s =~ tr/\[\]\\/\{\}\|/;
	return lc $s;
}

sub on_kick {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $channel =  fix_channel_name($bot->{decode}($_[ARG1] ),1);
	my $who =  $_[ARG2];
	my $msg = $bot->{decode}( $_[ARG3] );
	
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
}

sub on_invite {
#	my $bot = $_[SENDER]->get_heap()->{$TAG};
#	my $who =  $_[ARG0];
#	my $channel = $_[ARG1];
#	console "%s: invited to %s by %s",$bot->{Name},fix_channel_name($bot->{decode}($channel),1),$who;
#	$bot->{irc}->yield( join => $channel );
}

sub on_public {
	my $bot = $_[SENDER]->get_heap()->{$TAG};
	my $from = $_[ARG0];
	my $channel = $_[ARG1];
	my $msg = $bot->{decode}($_[ARG2]);
	if(ref $channel ){
		$channel = shift @$channel;
	}
#	console "on_public %s %s",$bot->{decode}($channel),$msg;
	handle_message( $_[KERNEL],$_[HEAP],$bot,$from,$channel,$msg);
}


slack_start();
$poe_kernel->run();
exit 0;
