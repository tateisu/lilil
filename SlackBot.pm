package SlackBot;
$SlackBot::VERSION = '0.161009'; # YYMMDD

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
	merge_message:b
));

sub check_config{
	return ConfigUtil::check_config_keywords(\%config_keywords,@_);
}

sub config_equals{
	my($a,$b)=@_;
	return
		( $a->{name} eq $b->{name} 
		and not ( $a->{disabled} xor $b->{disabled} )
		and $a->{api_token} eq $b->{api_token}
		and $a->{user_agent} eq $b->{user_agent}
		);
}

###############################################################

# これらのsubtype は通常メッセージと同じに扱う
our %subtype_thru = map{ ($_,1) } qw( file_share channel_join channel_leave );

# これらのsubtype は捨てる
our %subtype_drop = map{ ($_,1) } qw(
	channel_archive
	channel_unarchive
	channel_name
	channel_purpose
	channel_topic

	group_archive
	group_unarchive
	group_join
	group_leave
	group_name
	group_purpose
	group_topic
	
);

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
		
		tx_channel =>{},
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

# メッセージを送信可能な状態かどうか
sub is_ready{
	my $self = shift;
	return( not $self->{is_disposed} and $self->{conn} and $self->{conn}->is_ready );
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
			
			# チャンネルごとのキューをチェックする
			if( $self->{conn} and $self->{conn}->is_ready ){
				while( my($channel_id,$tx_channel) = each %{$self->{tx_channel}} ){
					$self->_flush_cue($channel_id,$tx_channel);
				}
			}

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
	$self->{tx_channel} = {};
	$self->{logger}->i("connection start..");
	

	$self->{conn} = SlackConnection->new(
		token => $self->{config}{api_token},
		ping_interval => $self->{config}{ping_interval},
		user_agent => $self->{config}{ping_interval},
	);

	$self->{conn}->on(
		# ignore some events
		[
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
				
				my $user = ($message->{user} || '?');
				
				# たまに起動直後に過去の自分の発言を拾ってしまう
				# 自分の発言はリレーしないようにする
				# また、自分によるメッセージ編集の結果を受信してしまうことがある。この場合は何もせずに無視したい
				if( defined $self->{bot_id} and $self->{bot_id} eq ($message->{user} || '?') ){
					## return $self->{logger}->d("ignore message from me.");
					return;
				}

				# Slackからのメッセージに割り込まれたら、送信メッセージのマージはやめる
				if( $message->{channel} ){
					my $tx_channel = $self->{tx_channel}{$message->{channel}};
					if( $tx_channel ){
						$tx_channel->{last_message} = undef;
						$self->{logger}->d("last_message reset.");
					}
				}

				if( not $message->{user} ){
					# dropboxのリンクなどを貼ると出て来る邪魔なメッセージを除去する
					return if $message->{subtype} eq "bot_message" and $message->{is_ephemeral};

					$self->{logger}->e("missing user? %s",dump($message));
					$message->{user}='?';
				}


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
							return $self->{logger}->e("ignore_user %s,%s,%s","id:$message->{user}",$from,$re);
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
					return $self->{logger}->w("missing channel. %s",dump($message));
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
						$self->_filter_and_relay( $message->{channel},"`$from` $line");
					}
				}
#				if( $message->{attachments} ){
#					for my $a (@{ $message->{attachments} }){
#						my $msg = $a->{title};
#					}
#				}
			};
			$@ and $self->{logger}->e("message handling failed. $@");
		},
		
		#送信した発言のtsが確定した。発言をまとめるのに使えそうだが…
		$SlackConnection::EVENT_REPLY_TO => sub{
			my($conn, $event_type, $reply) = @_;
			## $self->{logger}->d("EVENT_REPLY_TO: %s",dump($reply) );
			my $count_sending = 0;
			while( my($channel_id,$tx_channel) = each %{ $self->{tx_channel}} ){
				my $message = $tx_channel->{sending_message};
				next if not $message;
				if( $message->{_sending_id} ne $reply->{reply_to} ){
					++$count_sending;
					next;
				}
				$message->{ok} =  $reply->{ok};
				$message->{reply_to} =  $reply->{reply_to};
				$message->{text} = $reply->{text};
				$message->{ts} =  $reply->{ts};

				undef $tx_channel->{sending_message};
				$tx_channel->{last_message} = $message;
				$self->_flush_cue($channel_id,$tx_channel);
			}
			$count_sending > 0 and $self->{logger}->d("count_sending=$count_sending\n");
		},
	);
	$self->{conn}->start;
}

# Slackからのメッセージをチャンネルごとにフィルタしてから上流へリレー
sub _filter_and_relay {
	my($self,$channel_id,$msg)=@_;
	

	# 最近の発言と重複する内容は送らない
	my $ra = $self->{duplicate_check}{$channel_id};
	$ra or $ra = $self->{duplicate_check}{$channel_id} = [];
	if( grep {$_ eq $msg } @$ra ){
		return $self->{logger}->i("omit duplicate message %s",$msg);
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

##################################################
# リレー送信


# onTimerから定期的に呼ばれる。たまにキューに入ったメッセージを出力する
# チャンネルごとのキューをチェックする
sub _flush_cue{
	my($self,$channel_id,$tx_channel)=@_;

	return if not $channel_id;

	my $cue = $tx_channel->{cue};
	
	# キューがカラ
	return if not @$cue;
	
	# 何かメッセージを送信中
	if( $tx_channel->{sending_message} ){
		return $self->{logger}->v("waiting sending result. %s",dump($tx_channel->{sending_message}));
	}

	# 前回送信してから5秒間は送信しない
	my $now = time;
	return if $now - $tx_channel->{last_sending} < 3;

	# 許可されているなら既存メッセージの更新を試みる
	if( $self->{config}{merge_message} ){
		my $last_message = $tx_channel->{last_message};
		if( $last_message ){
			my $delta = $now - $last_message->{ts};
			if( $delta < 300 ){
				## $self->{logger}->d("last message: %s",$last_message->{text} );
				my $msg = $self->decode_message( $last_message->{text} ,1);
				my $count_line = 0;
				while(@$cue){
					my $cue_line = $cue->[0];
					last if length($msg) + length($cue_line) +1 >= 2048;
					$msg .= "\x0a" . $cue_line;
					shift @$cue;
					++ $count_line;
				}
				if( $count_line ){
					eval{
						my $msg_obj = {
							ts => $last_message->{ts}
							,channel => $channel_id
							,text => $msg
						};
						$tx_channel->{sending_message} = $msg_obj;
						$tx_channel->{last_sending} = $now;
						## $self->{logger}->d("update_message: %s",dump($msg_obj) );
						$self->{conn}->update_message( 
							$msg_obj 
							,sub{
								$self->{logger}->e("update_message failed. error=%s",@_);
								$tx_channel->{sending_message} = undef;
								$self->_flush_cue($channel_id,$tx_channel);
							}
							,sub{
								my($data)=@_;
								eval{
									if( not $data->{ok} ){
										$self->{logger}->d("update_message result. %s",dump($data));
										$self->{logger}->d("update_message failed. error=%s",$data->{error} );
										$tx_channel->{last_message} = undef;
									}else{
										my $last_message = $tx_channel->{last_message};
										$last_message and $last_message->{text} = $data->{text};
									}
								};
								$@ and $self->{logger}->e("update_message result handling error. %s",$@);
								$tx_channel->{sending_message} = undef;
								$self->_flush_cue($channel_id,$tx_channel);
							} 
						);
					};
					$@ and $self->{logger}->e("update_message failed. %s",$@);
					return;
				}
			}
		}
	}

	if( not $self->{config}{merge_message} ){
		# キュー中の一番古いメッセージの時刻が15秒以内である
		my $delta = time - $tx_channel->{cue_oldest_time};
		return if $delta < 15;
	}

	# キュー中のメッセージを束ねる
	my $msg = join "\n",@$cue;
	@$cue = ();

	# 送信する
	eval{
		my $msg_obj = 	{
				type => 'message'
				,channel => $channel_id
				,text => $msg
			#	,mrkdwn => JSON::false
			};
		$tx_channel->{last_sending} = $now;
		$tx_channel->{sending_message} = $msg_obj;
		$msg_obj->{_sending_id} = $self->{conn}->send( $msg_obj );
		## $self->{logger}->d("sending_message: %s",dump($msg_obj) );
	};
	$@ and $self->{logger}->w("send failed. %s",$@);
}

# slackのチャンネルにメッセージを送る
# $msg はUTF8フラグつきの文字列
sub send_message{
	my($self,$channel_id,$msg)=@_;

	return if $self->{is_disposed};

	my $tx_channel = $self->{tx_channel}{$channel_id};
	$tx_channel or $tx_channel = $self->{tx_channel}{$channel_id} = {
		cue => [],
		last_sending => 0,
	};
	my $cue = $tx_channel->{cue};

	@$cue or $tx_channel->{cue_oldest_time} = time;



	$msg = avoid_url_renamer($msg);

	push @$cue,SlackUtil::encode_entity($msg);
	if( $self->{conn} and $self->{conn}->is_ready ){
		$self->_flush_cue($channel_id,$tx_channel);
	}
}


sub decode_message{
	my($self,$src,$suppress_url_error) = @_;
	
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
			if( $suppress_url_error ){
				# ボットが出したメッセージの編集の時はここを通る
				$after .= SlackUtil::decode_entity( $1 );
			}else{
				# Slack->IRCのリレーの時はここを通る
				$after .= SlackUtil::decode_entity( $2 ) ." ".SlackUtil::decode_entity( $1 );
			}
		}else{
			# <url>
			$after .= SlackUtil::decode_entity( $link );
		}
	}
	$start < $end and $after .= SlackUtil::decode_entity( substr($src,$start,$end -$start ) );

	return $after;
}

sub avoid_url_renamer{
	my($in)=@_;
	
	my $out = '';
	my $last_end = 0;
	while( $in =~ /(\A|\s)(\w+:\/\/)?([^\sA-Z0-9\.-]+?)([A-Z0-9\.-]*\.[A-Z0-9]+)/ig ){
		my $start = $-[0];
		my $end = $+[0];
		if($start > $last_end ){
			$out .= substr( $in, $last_end, $start - $last_end );
		}
		my($head,$schema,$domain1,$domain2)=map {$_//''} ($1,$2,$3,$4);
		warn "0=$head,1=$schema,2=$domain1,3=$domain2\n";
		if( length($schema) <= 1 ){
			# http:// がないので妙な展開をさせたくない
			$out .= "$head$schema$domain1 $domain2";
		}else{
			# http:// があるので妙な展開も仕方がない？
			$out .= "$head$schema$domain1$domain2";
		}
		$last_end = $end;
	}
	if(length($in) > $last_end ){
		$out .= substr( $in, $last_end, length($in) - $last_end );
	}
	
}

1;
__END__

再接続やメッセージの基本的な解釈を入れたBlackボット。
リレーボット固有の実装があるので、特に汎用性はないと思う




