package ConfigUtil;
$ConfigUtil::VERSION = '0.161004'; # YYMMDD

use strict;
use warnings;
use Scalar::Util qw( reftype );

sub parse_config_keywords{
	return( map{ (split /:/,$_) } @_);
}

sub check_config_keywords{
	my($keywords,$config,$logger)=@_;
	my $valid = 1;

	while(my($name,$type)=each %$keywords){
		my $v = $config->{$name};
		if( $type eq 's' ){
			if( not $v or not length $v ){
				$logger->e( "config error: missing '%s'. string required.",$name );
				$valid = 0;
			}
		}elsif( $type eq 'd' ){
			if( not $v or not $v =~ /\A\d+\z/ ){
				$logger->e( "config error: missing '%s'. integer required.",$name );
				$valid = 0;
			}
		}elsif( $type eq 'a' ){
			if( not defined $v ){
				# Ž©“®‚Å•â‚¤
				$config->{$name} = [];
			}elsif( 'ARRAY' ne reftype $v ){
				$logger->w( "config warning: '%s' must be array-ref, but data type is %s.",$name,reftype($v) );
				# Ž©“®‚Å•â‚¤
				$config->{$name} = [];
			}
		}elsif( $type eq 'b' ){
			# boolean required. È—ª‚µ‚½‚çfalseˆµ‚¢
		}else{
			$logger->e( "implementation error: unknown type in config_keywords '$name'" );
			$valid = 0;
		}
	}
	while( my($name,$v) = each %{ $config } ){
		if( not $keywords->{$name} ){
			$logger->e( "config error: unknown keyword '$name'. maybe typo? " );
			$valid = 0;
		}
	}

	return $valid;
}


