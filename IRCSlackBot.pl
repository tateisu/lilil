#!/usr/bin/perl --
use utf8;
use strict;
use warnings;

# 外部依存関係
use AnyEvent;
use Time::HiRes qw(time);
use Scalar::Util qw( reftype );
use Data::Dump qw(dump);

# アプリ内モジュール
use Logger;
use SlackUtil;
use SlackBot;
use IRCUtil;
use IRCBot;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my $logger = Logger->new();
$logger->prefix("");

# 設定ファイル
my $config_file = shift // 'config.pl';
our $config;

my @slack_bots;
my @irc_bots;
my @relay_rules;
my %irc_channels;
my %slack_channels_id;
my %slack_channels_name;

sub reload{
	my($allow_die)=@_;

	$logger->d("loading $config_file ...");
	$config = do $config_file;
	$@ and die "$config_file : $@\n";
	
	my $valid = 1;
	
	if( 'ARRAY' ne reftype $config->{slack_connections} ){
		$logger->e(" 'slack_connections' is not array reference.");
		$valid = 0;
	}else{
		my %name;
		for my $conf_slack ( @{ $config->{slack_connections} } ){
			if( not SlackBot::check_config( $conf_slack, $logger ) ){
				$logger->e("slack_connections[$conf_slack->{name}] has error.");
				$valid = 0;
			}
			if( $name{ $conf_slack->{name} }++ ){
				$logger->e("slack_connections[$conf_slack->{name}] is duplicated.");
				$valid = 0;
			}
		}
	}
	
	if( 'ARRAY' ne reftype $config->{irc_connections} ){
		$logger->e(" 'irc_connections' is not array reference.");
		$valid = 0;
	}else{
		my %name;
		for my $conf_irc ( @{ $config->{irc_connections} } ){
			if( not IRCBot::check_config( $conf_irc, $logger ) ){
				$logger->e("irc_connections[$conf_irc->{name}] has error.");
				$valid = 0;
			}
			if( $name{ $conf_irc->{name} }++ ){
				$logger->e("irc_connections[$conf_irc->{name}] is duplicated.");
				$valid = 0;
			}
		}
	}

	if( 'ARRAY' ne reftype $config->{relay_rules} ){
		$logger->e(" 'relay_rules' is not array reference.");
		$valid = 0;
	}else{
		my $n = 0;
		for my $conf_relay ( @{ $config->{relay_rules} } ){
			if( not check_relay_config( $conf_relay, $logger ) ){
				$logger->e("relay_rules[$n] has error.");
				$valid = 0;
			}elsif( $conf_relay->{disabled} ){
				# 無効なのでチェックしない
			}else{
				$conf_relay->{irc_channel} = IRCUtil::fix_channel_name( $conf_relay->{irc_channel} ,1);
				$conf_relay->{irc_channel_lc} = IRCUtil::lc_irc( $conf_relay->{irc_channel} );
				
				my($conf_slack) = grep { $_->{name} eq $conf_relay->{slack_conn} } @{ $config->{slack_connections} };
				if( not $conf_slack ){
					$logger->e("relay_rules[$n]:slack_conn '$conf_relay->{slack_conn}' is not defined.");
					$valid = 0;
				}elsif( $conf_slack->{disabled} ){
					$logger->e("relay_rules[$n]:slack_conn '$conf_relay->{slack_conn}' is disabled.");
					$valid = 0;
				}

				my($conf_irc) = grep { $_->{name} eq $conf_relay->{irc_conn} } @{ $config->{irc_connections} };
				if( not $conf_irc ){
					$logger->e("relay_rules[$n]:irc_conn '$conf_relay->{irc_conn}' is not defined.");
					$valid = 0;
				}elsif( $conf_irc->{disabled} ){
					$logger->e("relay_rules[$n]:irc_conn '$conf_relay->{irc_conn}' is disabled.");
					$valid = 0;
				}else{
					my $channel = grep{ IRCUtil::lc_irc( IRCUtil::fix_channel_name($_,1) ) eq $conf_relay->{irc_channel_lc}} @{ $conf_irc->{auto_join} };
					if( not $channel ){
						# 自動で補う
						push @{ $conf_irc->{auto_join} }, $conf_relay->{irc_channel};
					}
				}
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

	for my $bot ( @slack_bots ){
		$bot->dispose;
	}
	undef @slack_bots;
	for my $c ( @{ $config->{slack_connections} } ){
		next if $c->{disabled};
		my $bot = new SlackBot(
			cb_channel => \&cb_slack_channel,
			cb_relay => \&cb_slack_relay,
			cb_status=> \&cb_status,
		);
		$bot->config( $c );
		$bot->{logger}->debug_level($debug_level);
		push @slack_bots,$bot;
	}
	
	for my $bot ( @irc_bots ){
		$bot->dispose;
	}
	undef @irc_bots;
	for my $c ( @{ $config->{irc_connections} } ){
		next if $c->{disabled};
		my $bot = new IRCBot(
			cb_channel => \&cb_irc_channel,
			cb_relay => \&cb_irc_relay,
			cb_status=> \&cb_status,
		);
		$bot->config( $c );
		$bot->{logger}->debug_level($debug_level);
		push @irc_bots,$bot;
	}
	
	@relay_rules = @{ $config->{relay_rules} };
}

sub check_relay_config{
	my( $relay, $logger )=@_;
	my $valid = 1;
	
	# required string
	for(qw( slack_conn slack_channel irc_conn irc_channel )){
		my $v = $relay->{$_};
		if( not defined $v or not length $v ){
			$logger->e("config error: missing $_");
			$valid = 0;
		}
	}
	$valid;
}

###########################################################
# callback for SlackBot

sub cb_slack_channel{
	my( $slack_bot, $channel ) = @_;
	my $v = {
		bot => $slack_bot,
		channel => $channel,
	};
	$slack_channels_id{ $slack_bot->{config}{name}."#".$channel->{id} }=$v;
	$slack_channels_name{ $slack_bot->{config}{name}."#".$channel->{name} }=$v;

	$logger->v("S\[%s\]channel %s \#%s",$slack_bot->{config}{name},$channel->{id},$channel->{name});
}

sub cb_slack_relay{
	my( $slack_bot,$channel_id,$msg) = @_;
	
	# find channel name by id
	my $v = $slack_channels_id{ $slack_bot->{config}{name}."#".$channel_id};
	$v or return $logger->w("unknown slack channel: %s %s",$slack_bot->{config}{name},$channel_id);
	my $slack_channel_name = '#'.$v->{channel}{name};

	my @errors;

	my $count_fanout = 0;

	for my $relay (@relay_rules){
		if( $relay->{slack_conn} ne $slack_bot->{config}{name} ){
			push @errors,"skip rule: slack_conn not match. $relay->{slack_conn} $slack_bot->{config}{name}";
			next;
		}
		if( $relay->{slack_channel} ne $slack_channel_name ){
			push @errors,"skip rule: slack_channel not match. $relay->{slack_channel} $slack_channel_name";
			next;
		}
		if( not $relay->{slack_to_irc} ){
			push @errors,"skip rule: slack_to_irc not set.";
			next;
		}
		if( $relay->{disabled} ){
			push @errors,"skip rule: disabled is set.";
			next;
		}

		#
		my $irc_to = $irc_channels{ $relay->{irc_conn} ."<>". $relay->{irc_channel_lc}};
		if(not $irc_to){
			$logger->w("unknown irc channel: %s %s",$relay->{irc_conn} , $relay->{irc_channel_lc});
			next;
		}

		#
		my $irc_bot = $irc_to->{bot};
		if(not $irc_bot->is_ready){
			$logger->w("not ready to relay: IRC %s %s",$relay->{irc_conn} , $relay->{irc_channel});
			next;
		}

		$logger->i("I[%s]=>%s %s",$relay->{irc_conn}, $relay->{irc_channel},$msg);
		$irc_bot->send('NOTICE',$irc_to->{channel_raw},$irc_bot->{encode}($msg));
		++$count_fanout;
	}
	if( not $count_fanout ){
		for(@errors){
			$logger->d("fanout failed. $_");
		}
	}
}

###########################################################
# callback for IRCBot

sub cb_irc_channel{
	my( $irc_bot, $channel_raw,$channel ) = @_;

	my $channel_lc = IRCUtil::lc_irc($channel);
	my $k = $irc_bot->{config}{name} ."<>". $channel_lc;
	my $v = {
		bot => $irc_bot,
		channel_raw =>  $channel_raw,
		channel => $channel,
		channel_lc => $channel_lc,
	};
	$irc_channels{$k}=$v;
	$logger->v("I\[%s\]channel %s",$irc_bot->{config}{name},$channel);
}

sub cb_irc_relay{
	my($irc_bot, $from_nick,$command,$channel_raw, $channel, $msg )=@_;

	my $channel_lc = IRCUtil::lc_irc( $channel );

	# find channel
	my $v = $irc_channels{ $irc_bot->{config}{name}."<>".$channel_lc};
	$v or return $logger->w("unknown IRC channel: %s %s",$irc_bot->{config}{name},$channel);

	my $is_notice = ($command =~ /notice/i);
	

	my $is_action = 0;
	if( $msg =~ s/\A\x01ACTION\s+(.+)\x01\z/$1/ ){
		$is_action = 1;
	}
	
	for my $relay (@relay_rules){
		next if $relay->{disabled} or not $relay->{irc_to_slack};
		next if $relay->{irc_conn} ne $irc_bot->{config}{name};
		next if $relay->{irc_channel_lc} ne $channel_lc;

		#
		my $slack_to = $slack_channels_name{ $relay->{slack_conn} . $relay->{slack_channel}};
		if( not $slack_to ){
			$logger->w("unknown slack channel: %s %s",$relay->{slack_conn} , $relay->{slack_channel});
			next;
		}

		#
		my $slack_bot = $slack_to->{bot};
		if( not $slack_bot->is_ready ){
			$logger->w("not ready to relay: Slack %s %s",$relay->{slack_conn} , $relay->{slack_channel});
			next;
		}
		if( $is_notice and $relay->{dont_relay_notice} ){
			$logger->v("NOTICEをリレーしない設定なので無視します");
			next;
		}

		$logger->i("S[%s]=>%s %s %s",$relay->{slack_conn}, $relay->{slack_channel},$from_nick,$msg);

		if( $is_action ){
			if( $is_notice ){
				$slack_bot->send_message( $slack_to->{channel}{id},"(action) [$from_nick] $msg");
			}else{
				$slack_bot->send_message( $slack_to->{channel}{id}, "(action) <$from_nick> $msg");
			}
		}else{
			if( $is_notice ){
				$slack_bot->send_message( $slack_to->{channel}{id}, "[$from_nick] $msg");
			}else{
				$slack_bot->send_message( $slack_to->{channel}{id}, "<$from_nick> $msg");
			}
		}
	}
}

###########################################################
# callback for >status command

sub cb_status{
	my @r;
	for( @slack_bots ){
		push @r,sprintf("Slack[%s]:%s",$_->{config}{name},$_->status);
	}
	for( @irc_bots ){
		push @r,sprintf("IRC[%s]:%s",$_->{config}{name},$_->status);
	}
	@r;
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
