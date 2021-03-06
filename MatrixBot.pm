package MatrixBot;
$MatrixBot::VERSION = '0.210305'; # YYMMDD

use strict;
use warnings;
use utf8;
use Encode;
use Data::Dump qw(dump);
use AnyEvent::HTTP;
use JSON::XS;
use URI::Escape;
use HTML::Entities;

use ConfigUtil;

my %config_keywords = ConfigUtil::parse_config_keywords(qw(

    name:s
    disabled:b

    serverPrefix:s
    mediaPrefix:s
    userAgent:s

    token:so
    user:so
    password:so
    timeout:do
));

sub check_config{
    my($params,$logger)=@_;
    my $valid = ConfigUtil::check_config_keywords(\%config_keywords,@_);

    if($valid){
        if(not ($params->{token} or ( $params->{user} and $params->{password} )) ){
            $logger->e( "config error: connection required 'token', or pair of 'user','password'.");
            $valid = 0;
        }
    }

	return $valid;
}

###########################################################

my $utf8 = Encode::find_encoding("utf8");

sub new {
	my $class = shift;

	return bless {
		logger => Logger->new(prefix=>"MatrixBot:"),
		cb_relay => sub{},
		cb_status => sub{},
        userLast => {},
        sendQueue =>[],
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
    delete $self->{reqReceive};
    delete $self->{reqSend};
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
	return "requesting" if $self->{reqReceive};
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
        if( $self->{config}{mediaPrefix} and $url =~ m|\Amxc://([^/]+)/([^/#?]+)\z| ){
            my($site,$code)=($1,$2);
            $url ="$self->{config}{mediaPrefix}$site/$code";
        }
        my $caption = $content->{body};
        $text = join " ",grep{ defined $_ and length $_ } ("(image)",$caption,$url);
    }elsif($msgType eq "m.audio"){
        my $url = $content->{url};
        if( $self->{config}{mediaPrefix} and $url =~ m|\Amxc://([^/]+)/([^/#?]+)\z| ){
            my($site,$code)=($1,$2);
            $url ="$self->{config}{mediaPrefix}$site/$code";
        }

        my $caption = $content->{body};
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

    for( split /[\x0d\x0a]+/,$text){
        s/\A\s+//;
        s/\s+\z//;
        next if not length;
        $self->{cb_relay}->( $self, $roomId, $sender, $_ );
    }

    return undef;
}

sub parseMessages{
    my($self,$root)=@_;
    my $joinRooms = $root->{rooms}{join} or return;
    while(my($roomId,$room)=each %$joinRooms ){
        my $events = $room->{timeline}{events} or next;
        for my $event (@$events){
            my $error = $self->parseMessageOne($roomId,$event);
            $self->{logger}->w("parseMessages:%s",$error) if $error;
        }    
    }
}

sub onTimerReceive{
	my $self = shift;

    my $expire = $self->{nextReceive}//0;
	my $now = time;
    my $remain = $expire -$now;
    return if $remain > 0;
    return if $self->{reqReceive};

    my $token = $self->{token} || $self->{config}{token};
    my $myselfId = $self->{myselfId} || $self->{config}{myselfId} ;
    my $nextBatch = $self->{nextBatch};

    $self->{nextReceive} = $now+3;

    if(not $token){
        my $user = $self->{config}{user};
        my $password = $self->{config}{password};
        my $loginType = "m.login.password";

        my $url = "$self->{config}{serverPrefix}/login";
        $self->showUrl("POST",$url);
        $self->{reqReceive} = http_post $url
            , encode_json( {type=>$loginType,user=>$user,password=>$password})
            , headers => { 'User-Agent',$self->{config}{userAgent} }
            , timeout => ($self->{config}{timeout} || 100)
            , sub {
                my($data,$headers)=@_;
                my $now = time;
                delete $self->{reqReceive};
                $self->{lastRead} = $now;
                return if $self->{is_disposed};

                if(not defined $data or not length $data){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
                }
                $self->{lastJson} = $utf8->decode($data);

                my $root = eval{ decode_json($data) };
                if($@){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("JSON parse error. %s","".$@);
                }

                $self->{token} = $root->{access_token};
                if(not $self->{token}){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("/login API failed. %s",$self->{lastJson});
                }

                $self->{logger}->i("logined.");
                $self->on_timer;
             };
    }elsif(not $myselfId){
        my $url = "$self->{config}{serverPrefix}/account/whoami?".encodeQuery({access_token=>$token});
        $self->showUrl("GET",$url);
        $self->{reqReceive} = http_get $url
            , headers => { 'User-Agent',$self->{config}{userAgent} }
            , timeout => ($self->{config}{timeout} || 100)
            , sub {
                my($data,$headers)=@_;
                my $now = time;
                delete $self->{reqReceive};
                $self->{lastRead} = $now;
                return if $self->{is_disposed};

                if(not defined $data or not length $data){
                    $self->{nextReceive} = $now+30;
                     return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
                }
                $self->{lastJson} = $utf8->decode($data);

                my $root = eval{ decode_json($data) };
                if($@){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("JSON parse error. %s","".$@);
                }

                $self->{myselfId} = $root->{user_id};
                if(not $self->{myselfId}){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("/account/whoami API failed. %s",  $self->{lastJson} );
                }
                $self->{logger}->i("whoami ok. %s",$self->{myselfId});
                $self->on_timer;
             };
    }else{
        # このAPI呼び出しはtimeoutまで待機しつつ、イベントが発生したらその時点で応答を返す
        my $params = { timeout=>30000 ,access_token=>$token };
        if(!$nextBatch){
            # first sync ( filtered)
            $params->{filter}='{"room":{"timeline":{"limit":1}}}';
        }else{
            $params->{filter}=0;
            $params->{since}=$nextBatch;
        }
        my $url = "$self->{config}{serverPrefix}/sync?".encodeQuery($params);
        $self->showUrl("GET",$url);
        $self->{reqReceive} = http_get $url
            , headers => { 'User-Agent',$self->{config}{userAgent} }
            , timeout => ($self->{config}{timeout} || 100)
            , sub {
                my($data,$headers)=@_;
                my $now = time;
                delete $self->{reqReceive};
                $self->{lastRead} = $now;
                return if $self->{is_disposed};

                if(not defined $data or not length $data){
                    # in case of Matrix, 500 read timeout is normally happen.
                    return if $headers->{Reason} =~ /read timeout/;

                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
                }

                $self->{lastJson} = $utf8->decode($data);

                my $root = eval{ decode_json($data) };
                if($@){
                    $self->{nextReceive} = $now+30;
                    return $self->{logger}->e("JSON parse error. %s","".$@);
                }

                my $sv = $root->{next_batch};
                if($sv){
                    $self->{nextBatch} = $sv;
                }else{
                    $self->{logger}->w("missing nextBatch. %s",$self->{lastJson});
                }

                $self->parseMessages($root);
                $self->on_timer;
            };
    }
}

###################################################################
# send 

# HTML Entitiesのエンコード。最小限に留める
sub encodeHtml($){ encode_entities($_[0], '<>&"') }

sub onTimerSend{
	my $self = shift;

    my $queue = $self->{sendQueue};
    return if not @$queue;

    my $token = $self->{token} || $self->{config}{token};
    if(not $token){
        @$queue =();
        return $self->{logger}->e("onTimerSend: missing token.");
    }

    # キューがたまり過ぎたら古い方を除去する
    @$queue > 200 and splice @$queue,0,@$queue-100;

    my $expire = $self->{nextSend}//0;
	my $now = time;
    my $remain = $expire -$now;
    return if $remain > 0;
    return if $self->{reqSend};

    my $item = shift @$queue;
    my($roomId,$msg)= @$item;

    # 名前部分をマークアップしたい
    my $formattedBody = $msg;
    if( not $formattedBody =~ s|\A(.*)`([^`]+)`(\s*)(.*)|encodeHtml($1)."<b>".encodeHtml($2)."</b>".$3.encodeHtml($4)|e ){
        $formattedBody = encodeHtml($formattedBody)
    }

    my $params = {
        msgtype=>"m.text", 
        format =>"org.matrix.custom.html",

        # スマホアプリは素のbodyをMarkdownデコードして表示する
        # < > 等が消えないようHTML Entitiyのエンコードが必要
        body=>encodeHtml($msg), 

        # WebUIはこちらのHTMLを使う
        formatted_body => $formattedBody,
    };

    $self->{nextSend} = $now +1;
    my $url = "$self->{config}{serverPrefix}/rooms/".uri_escape($roomId)."/send/m.room.message?".encodeQuery({access_token=>$token});
    $self->showUrl("POST",$url);
    $self->{reqSend} = http_post $url
        , encode_json($params)
        , headers => { 'User-Agent',$self->{config}{userAgent} }
        , timeout => ($self->{config}{timeout} || 100)
        , sub {
            my($data,$headers)=@_;
            my $now = time;
            delete $self->{reqSend};
            $self->{lastRead} = $now;
            return if $self->{is_disposed};

            if(not defined $data or not length $data){
                $self->{nextSend} = $now+5;
                return $self->{logger}->e("HTTP error. %s %s",$headers->{Status},$headers->{Reason});
            }

            my $lastJson = $utf8->decode($data);

            my $root = eval{ decode_json($data) };
            if($@){
                $self->{nextSend} = $now+5;
                return $self->{logger}->e("JSON parse error. %s","".$@);    
            }

            $root->{event_id} or $self->{logger}->d("post result. %s",$lastJson);
            # {"event_id":"$X0Z0Yza9VSj2BaYXj9KCgn6WL6rPX6K52hK2orf60Nk"}
        };
}

sub send{
    my($self,$roomId,$msg)=@_;
    my $queue = $self->{sendQueue};
    push @$queue,[$roomId,$msg];
    $self->onTimerSend();
}

################################################################

sub on_timer{
	my $self = shift;

    return if $self->{is_disposed};

    $self->onTimerReceive();
    $self->onTimerSend();
}

1;
__END__
