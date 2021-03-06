package SlackUtil;
$SlackUtil::VERSION = '0.161003'; # YYMMDD

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

1;
__END__
