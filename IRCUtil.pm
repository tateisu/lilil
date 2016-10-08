package IRCUtil;
$IRCUtil::VERSION = '0.161004'; # YYMMDD

use strict;
use warnings;

sub lc_irc($){
	my($s)=@_;
	$s =~ tr/\[\]\\/\{\}\|/;
	return lc $s;
}

sub fix_channel_name($$){
	my($channel,$short_safe_channel)=@_;
	# safe channel の長いprefix を除去する
	$short_safe_channel and $channel =~ s/^\!.{5}/!/;
	# 大文字小文字の統一
	$channel =~ tr/\[\]\\ABCDEFGHIJKLMNOPQRSTUVWXYZ/\{\}\|abcdefghijklmnopqrstuvwxyz/;
	#
	return $channel;
}

sub match_prefix_re_list{
	my($target,$re_list)=@_;
	if( $re_list ){
		for my $re (@$re_list){
			$target =~ /$re/ and return "".$re;
		}
	}
	return undef;
}
	