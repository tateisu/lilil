#!/usr/bin/perl --
use strict;
use warnings;
use utf8;
use LWP::UserAgent;
use Attribute::Constant;
use URI::Escape;
use JSON::XS;
use feature qw(say);

# CloudFlareさん対策
my $agent = $ENV{USER_AGENT} || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.72 Safari/537.36";

# export MATRIX_SERVER_PREFIX=https://matrix.fedibird.com/_matrix/client/r0
# ex: https://matrix.fedibird.com/_matrix/client/r0
my $serverPrefix = $ENV{MATRIX_SERVER_PREFIX} 
    or die "missing ENV{MATRIX_SERVER_PREFIX} , like as https://matrix.fedibird.com/_matrix/client/r0";

my $accessToken = $ENV{MATRIX_TOKEN};

# トークンがなければログインする
my $user = $ENV{MATRIX_USER};
my $password = $ENV{MATRIX_PASSWORD};

##################################################################

binmode $_,":encoding(utf8)" for \*STDOUT,\*STDERR;

my $ua = LWP::UserAgent->new(timeout => 30);
$ua->env_proxy;
$ua->agent($agent);

sub encodeQuery($){
    my($hash)=@_;
    return join "&",map{ uri_escape($_)."=".uri_escape($hash->{$_}) } sort keys %$hash;
}

my $methodGet : Constant("GET");

my $methodPost : Constant("POST");

my $lastJson;

sub showUrl($$){
    my($method,$url)=@_;
    return if index($url ,"/sync?")!=-1;
    $url=~ s/access_token=[^&]+/access_token=xxx/g;
    say "$method $url";
}

sub apiJson($$;$$){
	my($method,$path,$params,$headers)=@_;
    $headers //=[];
	
	my $url = "$serverPrefix$path";

    $accessToken and $url = "$url?access_token=".uri_escape($accessToken);

    my $delm = index($url,"?")==-1? "?":"&";

    my $res;

	if( $method eq $methodGet ){
		$params and $url = "$url$delm".encodeQuery($params);
        showUrl $method,$url;
		$res = $ua->get($url,@$headers);
    }elsif( $method eq $methodPost){
        showUrl $method,$url;
        if($params){
            $res = $ua->post( $url, Content => encode_json $params,@$headers);
        }else{
            $res = $ua->post( $url,@$headers);
        }
    }else{
        die("apiJson: unknown method '$method'");
    }

    $res->is_success or die $res->status_line;
    $lastJson = $res->decoded_content;
    decode_json( $res->content);
}

##################################################################

my $root;

# アクセストークンがなければログインする
if(!$accessToken){
    $user or die "missing ENV{MATRIX_USER}";
    $password or die "missing ENV{MATRIX_PASSWORD}";

    $root = apiJson($methodGet,"/login");

    my $loginType = "m.login.password";

    grep{ $_->{type} eq $loginType } @{$root->{flows}}
        or die "this server does not supports loginType '$loginType'. $lastJson";

    $root = apiJson(
        $methodPost,"/login",
        {type=>$loginType,user=>$user,password=>$password}
    );
    my $userId = $root->{user_id};
    my $homeServer = $root->{home_server};
    $accessToken = $root->{access_token};
    $accessToken or die "login failed. $lastJson";

    say "please export MATRIX_TOKEN=$accessToken";
    exit;
}

# get user id of login user
$root = apiJson($methodGet,"/account/whoami");
my $myselfId = $root->{"user_id"};
say "myselfId=$myselfId";

# space separated list
# Elementで部屋の設定→詳細 に表示される内部部屋 ID 
my $roomAliasList = $ENV{MATRIX_JOIN_ROOMS} || "!xQyixSzpkrbjaexNlL:matrix.fedibird.com";

# 指定された部屋にjoinする。既に参加済みでも応答は同じ
for my $roomAlias ( split /\s+/,$roomAliasList){
    next if not length $roomAlias;
    $root = apiJson($methodPost,"/join/".uri_escape($roomAlias),{});
    my $roomId = $root->{room_id} or die "missing roomId for roomAlias $roomAlias. $lastJson";
    say "join roomAlias=$roomAlias roomId=$roomId";
}

sub postMessage{
     my($roomId,$text)=@_;
     my $root = apiJson(
         $methodPost,
         "/rooms/".uri_escape($roomId)."/send/m.room.message",
        {msgtype=>"m.text", body=>$text},
     );
     # {"event_id":"$X0Z0Yza9VSj2BaYXj9KCgn6WL6rPX6K52hK2orf60Nk"}
}

my $firstRequest = time;

my %userLast;

sub parseMessages($){
    my( $root ) = @_;
    my $now = time;
    my $joinRooms = $root->{rooms}{join} or return;
    while(my($roomId,$room)=each %$joinRooms ){
        my $events = $room->{timeline}{events} or next;
        for my $event (@$events){

            # 初回syncより古い時刻は無視する
            my $time = $event->{origin_server_ts} / 1000.0;
            next if $time < $firstRequest;

            # メッセージイベント以外は無視する
            my $type = $event->{type};
            next if $type ne "m.room.message";

            my $sender = $event->{sender} || "?";

            # 自分からのメッセージは無視する
            next if $sender eq $myselfId;

            # ユーザごとにrate limitする
            my $lastList = $userLast{$sender};
            $lastList or $lastList = $userLast{$sender} = [];
            shift @$lastList while @$lastList && $lastList->[0] < $now - 60;
            push @$lastList,$now;
            if(@$lastList>12){
                warn "rate-limit from $sender";
                next;
            }

            my $content = $event->{content};
            my $msgType = $content->{msgtype};

            my $text;
            if( $msgType eq "m.text"){
                $text = $content->{body};
            }else{
                warn "unknown content type. ",encode_json($event->{content});
                next;
            }
            postMessage($roomId,"$time $sender $text");
        }    
    }
}

# periodically sync
my $nextBatch;
my $lastRequest =0;
while(1){

    # 短時間に何度もAPIを呼び出さないようにする
    my $now = time;
    my $remain = $lastRequest + 3 - $now;
    if( $remain >= 1 ){
        sleep($remain);
        next;
    }
    $lastRequest = $now;

    $root = eval{
        # このAPI呼び出しはtimeoutまで待機しつつ、イベントが発生したらその時点で応答を返す
        my $params = { timeout=>30000 };
        if(!$nextBatch){
            # first sync ( filtered)
            $params->{filter}= encode_json( {room=>{timeline=>{limit=>1}}});
        }else{
            $params->{filter}=0;
            $params->{since}=$nextBatch;
        }
        apiJson($methodGet,"/sync",$params);
    };

    my $error = $@;
    if($error){
        warn $error unless $error =~ /500 read timeout/;
        next;
    }

    my $sv = $root->{next_batch};
    if($sv){
        $nextBatch = $sv;
    }else{
        warn "missing nextBatch $lastJson";
    }

    parseMessages($root);
}
