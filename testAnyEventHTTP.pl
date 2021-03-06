#!/usr/bin/perl --
use strict;
use warnings;
use AnyEvent;
use AnyEvent::HTTP;
use Data::Dump;

my $c = AnyEvent->condvar;

print "a\n";
http_get "http://nonexistent.non/",sub{
	print Data::Dump::dump(\@_),"\n";
	$c->broadcast;
};

print "b\n";
$c->wait;
print "c\n";
exit 0;
