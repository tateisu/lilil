package MatrixBot;
$MatrixBot::VERSION = '0.210305'; # YYMMDD

use v5.14;
use strict;
use warnings;
use Encode;
use Data::Dump qw(dump);
use AnyEvent::HTTP;
use JSON::XS;
use URI::Escape;
use utf8;

use ConfigUtil;

my %config_keywords = ConfigUtil::parse_config_keywords(qw(
    disabled:b
    name:s
    serverPrefix:s
    user:so
    password:so
    token:so
    userAgent:s
));

sub check_config{
    my($params,$logger)=@_;
    my $valid = ConfigUtil::check_config_keywords(\%config_keywords,@_);
    if($valid){
        if(not $params->{token}){
            if( not $params->{user} ){
                $logger->e( "config error: missing both of 'token' and 'user'.");
				$valid = 0;
            }
            if( not $params->{password} ){
                $logger->e( "config error: missing both of 'token' and 'password'.");
				$valid = 0;
            }
        }
    }

	return $valid;
}

###########################################################

my $eucjp = Encode::find_encoding("EUC-JP");
my $utf8 = Encode::find_encoding("utf8");

sub new {
	my $class = shift;

	return bless {
		logger => Logger->new(prefix=>"MatrixBot:"),
		cb_relay => sub{},
		cb_status => sub{},
        userLast => {},
        created => time,
		@_,
	}, $class;
}

sub config{
	my($self,$config_new)=@_;
	if( $config_new ){
		$self->{config} = $config_new;
		my $name = $self->{config}{name} // '?';
		$self->{logger}->prefix( "M\[$name\]" );
	}
	return $self->{config};
}

sub dispose{
	my $self = shift;
	$self->{is_disposed} = 1;
    delete $self->{request};
}

sub is_ready{
	my $self = shift;

    my $token = $self->{token} || $self->{config}{token};
    my $myselfId = $self->{myselfId} || $self->{config}{myselfId} ;
    my $nextBatch = $self->{nextBatch};

    return 0 if $self->{is_disposed};
    return 0 if not $token or not $myselfId or not $nextBatch;

    return 1;
}

sub status{
	my $self = shift;
    my $token = $self->{token} || $self->{config}{token};
    my $myselfId = $self->{myselfId} || $self->{config}{myselfId} ;
    my $nextBatch = $self->{nextBatch};

	return "disposed" if $self->{is_disposed};
	return "requesting" if $self->{request};
	return "not login" if not $token;
	return "missing whoami" if not $myselfId;
    return "missing nextBatch" if not $nextBatch;
	
	my @lt = localtime($self->{lastRead});
	return sprintf("listening. last_rx=%d:%02d:%02d",reverse @lt[0..2]);
}

sub encodeQuery($){
    my($hash)=@_;
    return join "&",map{ uri_escape($_)."=".uri_escape($hash->{$_}) } sort keys %$hash;
}

sub showUrl{
    my($self,$method,$url)=@_;
    return if index($url ,"/sync?")!=-1;
    $url=~ s/access_token=[^&]+/access_token=xxx/g;
    $self->{logger}->d("%s %s",$method,$url);
}

sub on_timer{
	my $self = shift;

    # 破棄されたか、何かリクエストを処理中なら何もしない
    return if $self->{is_disposed} or $self->{request};

    my $expire = $self->{nextRequest}//0;
	my $now = time;
    my $remain = $expire -$now;
    return if $remain > 0;

    my $token = $self->{token} || $self->{config}{token};
    if(not $token){
        my $user = $self->{config}{user};
        my $password = $self->{config}{password};
        my $loginType = "m.login.password";

        $self->{nextRequest} = $now+3;

        my $url = "$self->{config}{serverPrefix}/login";
        $self->showUrl("POST",$url);

        $self->{request} = http_post $url
            , encode_json( {type=>$loginType,user=>$user,password=>$password})
            , headers => { 'User-Agent',$self->{config}{userAgent} }
            , sub {
                my($data,$headers)=@_;

                return if $self->{is_disposed};
                delete $self->{request};
                $self->{lastRead} = time;

                if(not defined $data or not length $data){
                    $self->{nextRequest} = $now+30;
                    return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
                }
                $self->{lastJson} = $utf8->decode($data);

                my $root = eval{ decode_json($data) };
                if($@){
                    $self->{nextRequest} = $now+30;
                    return $self->{logger}->e("JSON parse error. %s","".$@);
                }

                $self->{token} = $root->{access_token};
                if(not $self->{token}){
                    $self->{nextRequest} = $now+30;
                    return $self->{logger}->e("/login API failed. %s",$self->{lastJson});
                }

                $self->{logger}->i("logined.");
                $self->on_timer;
             };
        return;
    }

    # get user id of login user
    my $myselfId = $self->{myselfId} || $self->{config}{myselfId} ;
    if(not $myselfId){
        $self->{nextRequest} = $now+3;

        my $url = "$self->{config}{serverPrefix}/account/whoami?".encodeQuery({access_token=>$token});
        $self->showUrl("GET",$url);

        $self->{request} = http_get $url
            , headers => { 'User-Agent',$self->{config}{userAgent} }
            , sub {
                my($data,$headers)=@_;

                return if $self->{is_disposed};
                delete $self->{request};
                $self->{lastRead} = time;

                if(not defined $data or not length $data){
                    $self->{nextRequest} = $now+30;
                     return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
                }
                $self->{lastJson} = $utf8->decode($data);

                my $root = eval{ decode_json($data) };
                if($@){
                    $self->{nextRequest} = $now+30;
                    return $self->{logger}->e("JSON parse error. %s","".$@);
                }

                $self->{myselfId} = $root->{user_id};
                if(not $self->{myselfId}){
                    $self->{nextRequest} = $now+30;
                    return $self->{logger}->e("/account/whoami API failed. %s",  $self->{lastJson} );
                }
                $self->{logger}->i("whoami ok. %s",$self->{myselfId});
                $self->on_timer;
             };
        return;
    }

    my $nextBatch = $self->{nextBatch};

    # このAPI呼び出しはtimeoutまで待機しつつ、イベントが発生したらその時点で応答を返す
    my $params = { timeout=>30000 ,access_token=>$token };
    if(!$nextBatch){
        # first sync ( filtered)
        $params->{filter}='{"room":{"timeline":{"limit":1}}}';
    }else{
        $params->{filter}=0;
        $params->{since}=$nextBatch;
    }

    $self->{nextRequest} = $now+3;

    my $url = "$self->{config}{serverPrefix}/sync?".encodeQuery($params);
    $self->showUrl("GET",$url);

    $self->{request} = http_get $url
        , headers => { 'User-Agent',$self->{config}{userAgent} }
        , sub {
            my($data,$headers)=@_;

            return if $self->{is_disposed};
            delete $self->{request};
            $self->{lastRead} = time;

            if(not defined $data or not length $data){
                # in case of Matrix, 500 read timeout is normally happen.
                return if $headers->{Reason} =~ /read timeout/;

                $self->{nextRequest} = $now+30;
                return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
            }

            $self->{lastJson} = $utf8->decode($data);

            my $root = eval{ decode_json($data) };
            if($@){
                $self->{nextRequest} = $now+30;
                return $self->{logger}->e("JSON parse error. %s","".$@);
            }

            my $sv = $root->{next_batch};
            if($sv){
                $self->{nextBatch} = $sv;
                $self->{logger}->d("nextBatch=%s",$self->{nextBatch});
            }else{
                $self->{logger}->w("missing nextBatch. %s",$self->{lastJson});
            }
            $self->parseMessages($root);
            $self->on_timer;
        };
}

sub parseMessages{
    my($self,$root)=@_;

    my $joinRooms = $root->{rooms}{join};
    if(not $joinRooms){
        $self->{logger}->e("parseMessages: missing joinRooms.");
        return
    }

    my $nMessage =0;
    while(my($roomId,$room)=each %$joinRooms ){
        my $events = $room->{timeline}{events};
        if(not $events){
            $self->{logger}->e("parseMessages: room=%s, missing timeline events.",$roomId);
            next;
        }
        for my $event (@$events){
            ++$nMessage;
            my $error = $self->parseMessageOne($roomId,$event);
            $self->{logger}->w("parseMessages:%s",$error) if $error;
        }    
    }
    $self->{logger}->d(  "read %s messages.",$nMessage );
}

sub parseMessageOne{
    my($self,$roomId,$event) =@_;

    my $firstRequest = $self->{created};
    my $userLast = $self->{userLast};
    my $myselfId = $self->{myselfId};
    my $now = time;

    # 初回syncより古い時刻は無視する
    my $time = $event->{origin_server_ts} / 1000.0;
    return "too old message" if $time < $firstRequest;

    # メッセージイベント以外は無視する
    my $type = $event->{type};
    return "not message event $type" if $type ne "m.room.message";

    my $sender = $event->{sender} || "?";

    # 自分からのメッセージは無視する
    return "skip message from me" if $sender eq $myselfId;

    my $content = $event->{content};
    my $msgType = $content->{msgtype};

    my $text;
    if( $msgType eq "m.text"){
        $text = $content->{body};
    }elsif($msgType eq "m.image"){
        my $url = $content->{url};
        my $caption = $content->{body};
        if( $url =~ m|\Amxc://([^/]+)/([^/#?]+)\z| ){
            my($site,$code)=($1,$2);
            $url ="https://$site/_matrix/media/r0/download/$site/$code";
        }
        $text = join " ",grep{ defined $_ and length $_ } ("(image)",$caption,$url);
    }elsif($msgType eq "m.audio"){
        my $url = $content->{url};
        if( $url =~ m|\Amxc://([^/]+)/([^/#?]+)\z| ){
            my($site,$code)=($1,$2);
            $url ="https://$site/_matrix/media/r0/download/$site/$code";
        }

        my $caption = $content->{body};
        $self->{logger}->d("$msgType caption is_utf8=%s",utf8::is_utf8($caption));

        $text = join " ",grep{ defined $_ and length $_ } ("(audio)",$caption,$url);
    }else{
        $text = encode_json($content);
    }

    # ユーザごとにrate limitする
    my $lastList = $userLast->{$sender};
    $lastList or $lastList = $userLast->{$sender} = [];
    shift @$lastList while @$lastList && $lastList->[0] < $now - 60;
    push @$lastList,$now;
    return "rate-limit from $time $sender $text" if @$lastList>12;

    $self->{cb_relay}->( $self, $roomId, $sender, $text );
    return undef;
}

sub send{
    my($self,$roomId,$msg)=@_;

    my $token = $self->{token} || $self->{config}{token};
    $token or return $self->{logger}->e("send: missing token.");

    my $url = "$self->{config}{serverPrefix}/rooms/".uri_escape($roomId)."/send/m.room.message?".encodeQuery({access_token=>$token});
    $self->showUrl("POST",$url);
    http_post $url
        , encode_json({msgtype=>"m.text", body=>$msg})
        , headers => { 'User-Agent',$self->{config}{userAgent} }
        , sub {
            my($data,$headers)=@_;

            return if $self->{is_disposed};

            if(not defined $data or not length $data){
                return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
            }

            my $lastJson = $utf8->decode($data);

            my $root = eval{ decode_json($data) };
            if($@){
                return $self->{logger}->e("JSON parse error. %s","".$@);
            }
            $self->{logger}->d("post result. %s",$lastJson);
            # {"event_id":"$X0Z0Yza9VSj2BaYXj9KCgn6WL6rPX6K52hK2orf60Nk"}
        };
}

1;
__END__
