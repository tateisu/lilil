package SlackUtil;
$SlackUtil::VERSION = '0.161002'; # YYMMDD

use v5.14;
use strict;
use warnings;

sub encode_entity{
	my $msg = shift;
	$msg =~ s/&/&amp;/g;
	$msg =~ s/</&lt;/g;
	$msg =~ s/>/&gt;/g;
	$msg;
}

sub decode_entity{
	my($msg)=@_;
	$msg =~ s/&lt;/</g;
	$msg =~ s/&gt;/>/g;
	$msg =~ s/&amp;/&/g;
	return $msg;
}

sub decode_message{
	my($src) = @_;
	
	my $after = "";
	my $start = 0;
	my $end = length $src;
	while( $src =~ /<([^>]*)>/g ){
		my $link = $1;
		$after .= decode_entity( substr($src,$start,$-[0] - $start) );
		$start = $+[0];
		#
		if( $link =~ /([\#\@])[^\|]*\|(.+)/ ){
			$after .= decode_entity( $1.$2 );
		}elsif( $link =~ /[^\|]*\|(.+)/ ){
			$after .= decode_entity( $1 );
		}else{
			$after .= decode_entity( $link );
		}
	}
	$start < $end and $after .= decode_entity( substr($src,$start,$end -$start ) );

	return $after;
}

1;
__END__
