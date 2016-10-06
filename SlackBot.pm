package SlackBot;
$SlackBot::VERSION = '0.161002'; # YYMMDD

use v5.14;
use strict;
use warnings;
use utf8;

use ConfigUtil;
use SlackUtil;
use SlackConnection;

use Data::Dump qw(dump);

###############################################################
# 設定データの検証

my %config_keywords = ConfigUtil::parse_config_keywords(qw(
	name:s
	disabled:b
	api_token:s
	user_agent:s

	ping_interval:d
	user_list_interval:d

	ignore_user:a
	dump_all_message:b
));

sub check_config{
	return ConfigUtil::check_config_keywords(\%config_keywords,@_);
}

sub config_equals{
	my($a,$b)=@_;
	return $a->{name} eq $b->{name} 
	and not ( $a->{disabled} xor $b->{disabled} )
	and $a->{api_token} eq $b->{api_token}
	and $a->{user_agent} eq $b->{user_agent}
	;
}

###############################################################

# これらのsubtype は通常メッセージと同じに扱う
our %subtype_thru = map{ ($_,1) } qw( file_share channel_join channel_leave );

# これらのsubtype は捨てる
our %subtype_drop = map{ ($_,1) } qw(  );

sub new {
	my $class = shift;
	
	bless {
		last_connection_start => 0,
		conn => undef,
		bot_id => undef,
		bot_name => undef,
		user_map => {},
		user_map_update => 0,
		channel_map_id => {},
		channel_map_name => {},
		
		logger => Logger->new(prefix=>"SlackBot:"),
		
		tx_cue => {},
		tx_cue_oldest_time => {},
		duplicate_check => {},
		
		cb_relay => sub{},
		cb_status => sub{},
		
		@_,
	},$class;
}

sub dispose{
	my $self = shift;
	$self->{is_disposed} = 1;
	$self->{conn} and $self->{conn}->dispose;
}

sub status{
	my $self = shift;
	$self->{conn} ? $self->{conn}->status : "not connected";
}

sub config{
	my($self,$config_new)=@_;
	if( $config_new ){
		$self->{config} = $config_new;
		my $name = $config_new->{name} // '?';
		$self->{logger}->prefix( "S\[$name\]" );
	}
	return $self->{config};
}


sub on_timer{
	my $self = shift;
	
	return if $self->{is_disposed};

	if( $self->{conn} ){

		if( $self->{conn}->is_ping_timeout ){
			# ping応答が途切れているようなので、今の接続は閉じる
			$self->{logger}->e( "ping timeout.");
			$self->{conn}->dispose;
			undef $self->{conn};
			# fall thru. そのまま作り直す
		}else{
			$self->_start_user_list();
			$self->_flush_cue();
			
			
			# 再接続は必要ない
			return;
		}
	}
	
	# 前回接続開始してから60秒以内は何もしない
	my $now = time;
	my $remain = $self->{last_connection_start} + 60 -$now;
	$remain > 0 and return $self->{logger}->v( "waiting %d seconds to restart connection.",$remain );
	$self->{last_connection_start} = $now;
	
	# 設定がないなら接続できない
	$self->{config} or return $self->{logger}->e( "missing connection configuration" );
	
	$self->{user_map} = {};
	$self->{logger}->i("connection start..");

	$self->{conn} = SlackConnection->new(
		token => $self->{config}{api_token},
		ping_interval => $self->{config}{ping_interval},
		user_agent => $self->{config}{ping_interval},
	);

	$self->{conn}->on(
		# ignore some events
		[
			$SlackConnection::EVENT_REPLY_TO, #送信した発言のtsが確定した。発言をまとめるのに使えそうだが…

			'accounts_changed event', # 公式Webクライアントがユーザのログインアカウントのリストを更新するのに使われる。他のクライアントはこのイベントを無視するべき
			'reconnect_url', # The reconnect_url event is currently unsupported and experimental.
			'presence_change', # このボットはユーザのアクティブ状態に興味がない
			'file_public', #  A file was made public
			'file_shared', #  A file was shared
			'user_typing',# このボットはユーザの入力中状態に興味がない
			'pong',# pingへの応答
			'reaction_added', # リアクション追加は無視する
			'team_pref_change', #チーム設定の変化
			'team_rename', #チーム名の変化
			'email_domain_changed', # The team email domain has changed
			'emoji_changed', # 絵文字の登録、変更
			'dnd_updated_user', # Do not Disturb settings changed for a team member
			'dnd_updated', # Do not Disturb settings changed for the current user
			
		] => sub{},

		$SlackConnection::EVENT_CATCH_UP => sub {
			my(undef, $event_type, @args) = @_;
			$self->{logger}->i( "catch up event. $event_type %s",dump(\@args));
		},

		$SlackConnection::EVENT_RTM_CONNECTION_FINISHED => sub {
			$self->{logger}->i("connection finished.");
			$self->{conn}->dispose;
			undef $self->{conn};
		},

		$SlackConnection::EVENT_ERROR => sub {
			my(undef,$event_type,$error)=@_;
			$self->{logger}->i("error. $error");
			$self->{conn}->dispose;
			undef $self->{conn};
		},

		$SlackConnection::EVENT_SELF => sub {
			my(undef, $event_type, $user) = @_;
			$self->{bot_id} = $user->{id} if $user->{id};
			$self->user_update( $user );
		},

		$SlackConnection::EVENT_CHANNELS => sub {
			my(undef, $event_type, $channel_list) = @_;
		    for my $channel ( @$channel_list ){
				$self->channel_update( $channel);
			}

		},
		[qw(channel_joined channel_created)]=> sub {
			my(undef, $event_type, $data) = @_;
			my $channel = $data->{channel};
			$self->channel_update( $channel );
			$self->{logger}->i("$event_type: $channel->{id},$channel->{name}");
		},

		[ $SlackConnection::EVENT_USERS , $SlackConnection::EVENT_BOTS ] => sub {
			my(undef, $event_type, $list) = @_;

		    for my $user ( @$list ){
				$self->user_update( $user );
			}

			$self->{logger}->i("$event_type. user_map.size=%s", scalar( %{ $self->{user_map} } ) );
			$self->{user_map_update} = time;
		},
		[qw( team_join user_change bot_added bot_changed)] => sub{
			my(undef, $event_type, $data) = @_;
			my $user = ( $data->{user} // $data->{bot} );
			$self->user_update( $user );
			$self->{logger}->i("$event_type: $user->{id},$user->{name}");
		},
		
		
		$SlackConnection::EVENT_TEAM => sub {} ,
		$SlackConnection::EVENT_GROUPS => sub {} ,
		$SlackConnection::EVENT_MPIMS => sub {} ,
		$SlackConnection::EVENT_IMS => sub {} ,

		hello => sub {
			$self->{logger}->i("connection ready.");
		},

		message => sub {
			my($conn, $event_type, $message) = @_;

			return if $self->{is_disposed};

			if( $self->{config}{dump_all_message} ){
				$self->{logger}->d("dump_all_message: %s",dump($message) );
			}

			eval{
				$message->{subtype}='' if not defined $message->{subtype};
				if( $message->{subtype} eq 'message_changed'){
					my $old_channel = $message->{channel};
					$message = $message->{message};
					$message->{channel} = $old_channel if not $message->{channel};
					$message->{subtype}='' if not defined $message->{subtype};
				}

				if( not $message->{user} ){
					# dropboxのリンクなどを貼ると出て来る邪魔なメッセージを除去する
					return if $message->{subtype} eq "bot_message" and $message->{is_ephemeral};

					$self->{logger}->e("missing user? %s",dump($message));
					$message->{user}='?';
				}

				# たまに起動直後に過去の自分の発言を拾ってしまう
				# 自分の発言はリレーしないようにする
				return if defined $self->{bot_id} and $self->{bot_id} eq $message->{user};

				# 発言者のIDと名前を調べる
				my $member;
				if( $message->{user_profile} ){
					$member = $self->{user_map}{ $message->{user} } = $message->{user_profile};
				}else{
					$member = $self->{user_map}{ $message->{user} };
				}
				my $from =  (not defined $member ) ? "id:$message->{user}" : $member->{name};


				if( $self->{config}{ignore_user} ){
					for my $re ( @{$self->{config}{ignore_user}} ){
						if( "id:$message->{user}" =~ /$re/ or $from =~ /$re/ ){
							$self->{logger}->e("ignore_user %s,%s,%s","id:$message->{user}",$from,$re);
							return;
						}
					}
				}

				# メッセージ本文
				my $msg = $message->{text};
				if( defined $message->{message} and not defined $msg ){
					$msg = $message->{message}{text};
				}

				my $bot_name = $self->{bot_name};

				# pingコマンド
				if( not $message->{subtype} and $bot_name ){
					if( $msg =~ /\A\s*$bot_name&gt;ping\s*\z/i ){
						$conn->send({
							type => 'message'
							,channel => $message->{channel}
							,text => SlackUtil::encode_entity( $from.">pong" )
						});
						return;
					}elsif( $msg =~ /\A\s*$bot_name&gt;status\s*\z/i ){
						my @status = $self->{cb_status}();
						$conn->send({
							type => 'message'
							,channel => $message->{channel}
							,text => SlackUtil::encode_entity( join "\n","status:",@status )
						});
						return;
					}
				}
				
				# メッセージの宛先が不明
				if( not defined $message->{channel} ){
					$self->{logger}->w("missing channel. %s",dump($message));
					return;
				}

				if( $message->{subtype} ){
					if( $subtype_thru{ $message->{subtype} } ){
						# ダンプしないが普通のメッセージと同じに扱う
					}elsif( $subtype_drop{ $message->{subtype} } ){
						# リレーしない
						return;
					}else{
						# 未知のsubtype
						$self->{logger}->w("unknown subtype? %s",dump($message));
					}
				}

				if( defined $msg and length $msg ){
					my @lines = split /[\x0d\x0a]+/,$self->decode_message($msg);
					for my $line (@lines){
						next if not ( defined $msg and length $msg ) ;
						$self->_filter_and_relay( $message->{channel},"<$from> $line");
					}
				}
#				if( $message->{attachments} ){
#					for my $a (@{ $message->{attachments} }){
#						my $msg = $a->{title};
#					}
#				}
			};
			$@ and $self->{logger}->e("message handling failed. $@");
		}
	);
	$self->{conn}->start;
}

my @duplicate_check;

sub _filter_and_relay {
	my($self,$channel_id,$msg)=@_;
	

	# 最近の発言と重複する内容は送らない
	my $ra = $self->{duplicate_check}{$channel_id};
	$ra or $ra = $self->{duplicate_check}{$channel_id} = [];
	if( grep {$_ eq $msg } @$ra ){
		$self->{logger}->i("omit duplicate message %s",$msg);
		return;
	}
	push @$ra,$msg;
	shift @$ra if @$ra > 10;

	# 後はリレー先で処理する
	$self->{cb_relay}( $self,$channel_id,$msg);
}

# onTimerから定期的に呼ばれる。たまにユーザ一覧を更新する
sub _start_user_list{
	my $self = shift;

	# 接続状態によっては何もしない
	return if not $self->{conn} or not $self->{conn}->is_ready;
	
	# 前回更新してから一定時間が経過するまで何もしない
	my $now = time;
	return if $now - $self->{user_map_update} < $self->{config}{user_list_interval};
	$self->{user_map_update} = $now;

	# 更新を開始(非同期API)
	$self->{logger}->i("get slack user list..");
	$self->{conn}->get_user_list(sub{
		my $error = shift;
		$self->{logger}->i("user list update failed: $error");
	});
}

# ユーザ情報を受信した
sub user_update{
	my($self,$user)=@_;

	# ignore incomplete user information
	return if not $user->{id};

	$self->{user_map}{ $user->{id} } = $user;

	if( $self->{bot_id} and $self->{bot_id} eq $user->{id} ){
		$self->{bot_name} = $user->{name} if $user->{name};
		$self->{logger}->i("me: %s \@%s",$user->{id},$user->{name});
	}
}

sub channel_update{
	my($self,$channel)=@_;
	$self->{channel_map_id}{ $channel->{id} } = $channel;
	$self->{channel_map_name}{ '#'.$channel->{name} } = $channel;
	$self->{logger}->v("channel: %s \#%s",$channel->{id},$channel->{name});
}

sub find_channel_by_id{
	my($self,$id)=@_;
	return $self->{channel_map_id}{ $id };
}
sub find_channel_by_name{
	my($self,$name)=@_;
	return $self->{channel_map_name}{ $name };
}

# onTimerから定期的に呼ばれる。たまにキューに入ったメッセージを出力する
sub _flush_cue{
	my $self = shift;

	return if not $self->{conn} or not $self->{conn}->is_ready;
	
	while( my($channel_id,$cue) = each %{$self->{tx_cue}} ){

		next if not @$cue or not $channel_id;

		my $delta = time - $self->{tx_cue_oldest_time}{$channel_id};
		next if $delta < 15;
		
		my $msg = join "\n",@$cue;
		@$cue = ();

		eval{
			$self->{conn}->send(
				{
					type => 'message'
					,channel => $channel_id
					,text => $msg
				#	,mrkdwn => JSON::false
				}
			);
		};
		$@ and $self->{logger}->w("send failed. %s",$@);
	}
}

# メッセージを送信可能な状態かどうか
sub is_ready{
	my $self = shift;
	not $self->{is_disposed} and $self->{conn} and $self->{conn}->is_ready;
}

# slackのチャンネルにメッセージを送る
# $msg はUTF8フラグつきの文字列
sub send_message{
	my($self,$channel_id,$msg)=@_;

	return if $self->{is_disposed};
	
	my $cue = $self->{tx_cue}{$channel_id};
	$cue or $cue = $self->{tx_cue}{$channel_id} = [];

	@$cue or $self->{tx_cue_oldest_time}{$channel_id} = time;

	push @$cue,SlackUtil::encode_entity($msg);
}


sub decode_message{
	my($self,$src) = @_;
	
	my $after = "";
	my $start = 0;
	my $end = length $src;
	while( $src =~ /<([^>]*)>/g ){
		my $link = $1;
		$after .= SlackUtil::decode_entity( substr($src,$start,$-[0] - $start) );
		$start = $+[0];
		if( $link =~ /\A([\#\@])[^\|]*\|(.*)\z/ ){
			# <@user_id|username>
			# <#channel_id|channel_name>
			$after .= SlackUtil::decode_entity( $1.$2 );
		}elsif( $link =~ /\A\@([^\|]*)\z/ ){
			# <@user_id>
			my $user = $self->{user_map}{ $1 };
			$after .= SlackUtil::decode_entity( $user ? '@'.$user->{name} : $link );
		}elsif( $link =~ /\A\#([^\|]*)\z/ ){
			# <#channel_id>
			my $channel = $self->{channel_map_id}{ $1 };
			$after .= SlackUtil::decode_entity( $channel ? '#'.$channel->{name} : $link );
		}elsif( $link =~ /([^\|]*)\|(.*)/ ){
			# <url|caption>
			$after .= SlackUtil::decode_entity( $2 ) ." ".SlackUtil::decode_entity( $1 );
		}else{
			# <url>
			$after .= SlackUtil::decode_entity( $link );
		}
	}
	$start < $end and $after .= SlackUtil::decode_entity( substr($src,$start,$end -$start ) );

	return $after;
}



1;
__END__

再接続やメッセージの基本的な解釈を入れたBlackボット。
リレーボット固有の実装があるので、特に汎用性はないと思う




