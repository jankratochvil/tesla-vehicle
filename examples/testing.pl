use warnings;
use strict;
use feature 'say';

use Data::Dumper;
use Tesla::Vehicle;

my $x = Tesla::Vehicle->new(auto_wake => 1);

print Dumper $x->charging_sites_nearby;