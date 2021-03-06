package Logger;

use v5.26;
use strict;
use warnings;
use utf8;

use Attribute::Constant;

our $LEVEL_ERROR :Constant(1); # error
our $LEVEL_WARNING :Constant(2); # warning
our $LEVEL_INFO :Constant(3); # information for user
our $LEVEL_VERBOSE :Constant(4); # verbose information
our $LEVEL_DEBUG :Constant(5); # heart beat 

sub parse_debug_level {
	my($str)=@_;
	if($str){
		return $LEVEL_ERROR if $str =~ /err/i;
		return $LEVEL_WARNING if $str =~ /warn/i;
		return $LEVEL_INFO if $str =~ /info/i;
		return $LEVEL_VERBOSE if $str =~ /verb/i;
		return $LEVEL_DEBUG if $str =~ /debug/i;
	}
	return undef;
}

sub string_debug_level {
	my($lv) = @_;
	if($lv){
		return 'error' if $lv == $LEVEL_ERROR;
		return 'warning' if $lv == $LEVEL_WARNING;
		return 'info' if $lv == $LEVEL_INFO;
		return 'verbose' if $lv == $LEVEL_VERBOSE;
		return 'debug' if $lv == $LEVEL_DEBUG;
	}
	return '?';
}

sub new {
	my $class = shift;
	
	return bless {
		debug_level => $LEVEL_DEBUG,
		prefix => '',
		@_,
	},$class;
}

sub debug_level{
	my $self = shift;
	my $v = @_ ? $_[0] : undef;
	if($v){
		if( $v =~ /\A\d+\z/ and $LEVEL_ERROR <= $v and $v <= $LEVEL_DEBUG ){
			$self->{debug_level} = 0+ $v;
		}else{
			$v = parse_debug_level($v);
			$v and $self->{debug_level} = $v;
		}
	}
	return $self->{debug_level};
}

sub prefix{
	my $self = shift;
	my $v = @_ ? $_[0] : undef;
	defined($v) and $self->{prefix} = $v;
	return $self->{prefix};
}

sub clone{
	my $self = shift;
	return bless { %$self }, ref $self;
}

sub log{
	my($self,$lv,@args)=@_;

	return if $lv > $self->{debug_level};

	my @lt = localtime;
	$lt[5]+=1900;
	$lt[4]+=1;

	printf STDERR "%d:%02d:%02d_%d:%02d:%02d %s",(reverse @lt[0..5]),$self->{prefix};
	printf STDERR @args;
	print STDERR "\n";
}

sub e{ shift->log( $LEVEL_ERROR, @_ ) }
sub w{ shift->log( $LEVEL_WARNING, @_ ) }
sub i{ shift->log( $LEVEL_INFO, @_ ) }
sub v{ shift->log( $LEVEL_VERBOSE, @_ ) }
sub d{ shift->log( $LEVEL_DEBUG, @_ ) }

1;
__END__
