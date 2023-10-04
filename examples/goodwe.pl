#!/usr/bin/env perl
use warnings;
use strict;
use feature 'say';
use POSIX;
use Tesla::Vehicle;
require LWP::UserAgent;
require HTTP::CookieJar::LWP;
require JSON;
use Data::Dumper; $Data::Dumper::Deepcopy=1; $Data::Dumper::Sortkeys=1;
use DateTime;
$|=1;

my $BATTERY_CRITICAL=45;
my $BATTERY_MAINTAIN=50;
my $CHARGE_AMPS=5;
my $EXTRA_ON=1.5;
my $EXTRA_OFF=1.1;

my($powerstation,$account,$pwd);
my $fn=$ENV{"HOME"}."/.goodwe.pl";
open F,$fn or die "$fn: $!\n";
(my $F=do { local $/; <F>; }) or die "read $fn: $!\n";
close F or die "close $fn: $!\n";
eval $F;
$powerstation&&$account&&$pwd or die $fn.': need $powerstation $account $pwd'."\n";

my($jar,$ua,%token,$api);
sub relogin() {
  $jar=HTTP::CookieJar::LWP->new();
  $ua=LWP::UserAgent->new(
    "keepalive"=>1,
    "cookie_jar"=>$jar,
    "timeout"=>10,
    "agent"=>"PVMaster/2.0.4 (iPhone; iOS 11.4.1; Scale/2.00)",
  );
  %token=(
    "version"=>"v2.0.4",
    "client"=>"ios",
    "language"=>"en",
  );
  sub retoken() {
    $ua->default_header("Token"=>JSON::encode_json(\%token));
  }
  retoken();
  sub check($$;$) {
    my($res,$msg,$msg2)=@_;
    die $res->as_string() if !$res->is_success();
    my $json=JSON::decode_json($res->content());
    die "res hasError" if $json->{"hasError"};
    return undef if $msg2&&$json->{"msg"} eq $msg2;
    die "res msg '".$json->{"msg"}."'!='$msg'" if $json->{"msg"} ne $msg;
    return $json;
  }

  my $res1json=check($ua->post(
    "https://semsportal.com/api/v2/PowerStation/GetMonitorDetailByPowerstationId",
    [
      "powerStationId"=>$powerstation,
    ],
  ),"No access, please log in.");
  ;

  my $res2json=check($ua->post(
    "https://semsportal.com/api/v2/Common/CrossLogin",
    [
      "account"=>$account,
      "pwd"=>$pwd,
    ],
  ),"Successful");
  $token{$_}=$res2json->{"data"}->{$_} for qw(uid timestamp token);
  retoken();
  $api=$res2json->{"api"};
}

sub data() {
  for my $attempt (0,1) {
    relogin() if !$api;
    my $res3json=check($ua->post(
      "${api}v2/PowerStation/GetMonitorDetailByPowerstationId",
      [
	"powerStationId"=>$powerstation,
      ],
    ),"success","The authorization has expired, please log in again.");
    return $res3json->{"data"} if $res3json;
    relogin();
  }
  die "login twice?";
}

my $car=Tesla::Vehicle->new(auto_wake=>1);

my $cmd_ran;
my $opt_n;
sub cmd($@) {
  my($cmd,@args)=@_;
  my $setter=@args||$cmd=~/_(?:on|off|lock|unlock)$/;
  $cmd_ran=1 if $setter&&!$opt_n;
  my %suffixl=("charge_limit_set"=>"%","charge_amps_set"=>"A");
  my %suffixr=("battery_level"=>"%","charge_limit_soc"=>"%");
  my $rhs;
  if ($setter&&$opt_n) {
    $rhs="-n";
  } else {
    $rhs=$car->$cmd(@args);
    $rhs="ok" if $setter&&$rhs&&$rhs eq 1;
    $rhs.=$suffixr{$cmd}//"";
  }
  say join(" ",$cmd,map $_//"undef",@args).($suffixl{$cmd}//"").": $rhs";
  return $rhs;
}

my $tesla_timestamp;
while (1) {
  my $now=DateTime->now();
  $now->set_time_zone("local");
  print $now->iso8601().$now->time_zone_short_name()."\n";
  $tesla_timestamp||=time();
  my $battery_level=$car->battery_level;
  print "battery_level=$battery_level\n";
  my $charging_state=$car->charging_state;
  print "charging_state=$charging_state\n";
  die "Battery $battery_level<$BATTERY_CRITICAL=BATTERY_CRITICAL" if $battery_level<$BATTERY_CRITICAL;
  die "Battery $battery_level>$BATTERY_MAINTAIN=BATTERY_MAINTAIN" if $battery_level>$BATTERY_MAINTAIN;
  my $charge_amps=$car->charge_amps;
  die "Charging not reduced $charge_amps!=$CHARGE_AMPS=CHARGE_AMPS" if $charge_amps!=$CHARGE_AMPS;
  die "Charging $charging_state not expected" if $charging_state!~/^(?:Charging|Complete|Stopped)$/; #"Disconnected"?
  # This can happen for 48% or 49%
  #die "Low battery $battery_level<$BATTERY_MAINTAIN=BATTERY_MAINTAIN but Complete?" if $battery_level<$BATTERY_MAINTAIN&&$charging_state eq "Complete";
  my $wanted;
  my $sleep;
  my $hour=(localtime)[2];
  my $day=$hour>=6&&$hour<18;
  print "day=".($day?1:0)."\n";
  if ($battery_level>=$BATTERY_MAINTAIN&&$charging_state ne "Charging") {
    $wanted=0;
    $sleep=24*60*60;
  } else {
    my $data=data();
    my $pmeter=$data->{"inverter"}[0]{"invert_full"}{"pmeter"};
    die Dumper $data."\n!pmeter" if !defined $pmeter;
    print "pmeter=$pmeter\n";
    if ($charging_state eq "Charging") {
      my $data=data();
      my $limit=$CHARGE_AMPS*230*3*($EXTRA_OFF-1);
      $wanted=$pmeter>$limit;
      print "Stopping charging as pmeter=$pmeter<=$limit=limit\n" if !$wanted;
      $sleep=15;
    } elsif ($charging_state eq "Complete") {
      # We are at 48% or 49%
      my $limit=$CHARGE_AMPS*230*3*$EXTRA_OFF;
      $wanted=$pmeter>$limit;
      print "Stopping charging as pmeter=$pmeter<=$limit=limit\n" if !$wanted;
      $sleep=1*60;
    } else {
      die if $charging_state ne "Stopped";
      # We are at 48% or 49%
      my $limit=$CHARGE_AMPS*230*3*$EXTRA_ON;
      $wanted=$pmeter>$limit;
      print "Resuming charging as pmeter=$pmeter>$limit=limit\n" if $wanted;
      $sleep=$day?10*60:60*60;
    }
  }
  print "wanted=".($wanted?1:0)." sleep=$sleep\n";
  if ($wanted!=($charging_state ne "Stopped")) {
    die if !cmd "charge_".($wanted?"on":"off");
    $tesla_timestamp=undef;
    $sleep=60;
  }
  print "sleep=$sleep\n";
  die if $sleep!=sleep $sleep;
  if ($tesla_timestamp&&time()-$tesla_timestamp>23*60*60) {
    print "Tesla data have expired.\n";
    $car->api_cache_clear;
    $tesla_timestamp=undef;
  }
}
