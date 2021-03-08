package ConfigUtil;
$ConfigUtil::VERSION = '0.161006'; # YYMMDD

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
			if( not defined $v or not length $v ){
				$logger->e( "config error: '%s' is required. please set string value.",$name );
				$valid = 0;
			}
			
		}elsif( $type eq 'so' ){
			# string,optional

		}elsif( $type eq 'd' ){
			if( not defined $v or not $v =~ /\A\d+\z/ ){
				$logger->e( "config error: '%s' is required. please set integer value.",$name );
				$valid = 0;
			}
		}elsif( $type eq 'do' ){
			if( not defined $v or not length $v ){
				# digits,optional
			}elsif( not $v =~ /\A\d+\z/ ){
				$logger->e( "config error: '%s' is optional, or set integer value.",$name );
				$valid = 0;
			}

		}elsif( $type eq 'a' ){
			if( not defined $v ){
				# supply empty array
				$config->{$name} = [];
			}elsif( 'ARRAY' ne reftype $v ){
				$logger->e( "config warning: '%s' is required. please set array-ref. specified data is %s.",$name,reftype($v) );
				$valid = 0;
			}

		}elsif( $type eq 'ao' ){
			if( not defined $v ){
				# array optional
			}elsif( 'ARRAY' ne reftype $v ){
				$logger->e( "config warning: '%s' is optional, or set array-ref value, specified data is %s.",$name,reftype($v) );
				$valid = 0;
			}
		}elsif( $type eq 'ho' ){
			if( not defined $v ){
				# array optional
			}elsif( 'HASH' ne reftype $v ){
				$logger->e( "config warning: '%s' is optional, or set hash-ref value, specified data is %s.",$name,reftype($v) );
				$valid = 0;
			}


		}elsif( $type eq 'b' ){
			# boolean required.
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


