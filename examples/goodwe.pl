#!/usr/bin/env perl
use warnings;
use strict;
use feature 'say';
use POSIX;
BEGIN {
  *CORE::GLOBAL::exit=sub(;$) { die "exit(@_) override"; };
  $ENV{"TESLA_DEBUG_ONLINE"}="0";
  $ENV{"TESLA_DEBUG_API_RETRY"}="1";
  $ENV{"DEBUG_TESLA_API_CACHE"}="0";
}
use Tesla::Vehicle;
use Time::HiRes qw(time);
require LWP::UserAgent;
require HTTP::CookieJar::LWP;
require JSON;
require UUID;
use Data::Dumper; $Data::Dumper::Deepcopy=1; $Data::Dumper::Sortkeys=1;
use DateTime;
$|=1;
$ENV{"TZ"}="Europe/Prague";
tzset();

my $BATTERY_CRITICAL=45;
my $BATTERY_OFF=50;
my $BATTERY_ON=51;
my $CHARGE_AMPS=5;
my $SAFETY_RATIO_BIGGER=1.5;
my $SAFETY_RATIO_SMALLER=1.1;
my $TESLA_TIMEOUT_CHARGING=60;
my $TESLA_TIMEOUT_NOT_CHARGING=12*60*60;
my $WATT_PER_AMP_1=770;
my $AMP_TOP=16;
my $WATT_PER_AMP_TOP=733;

$BATTERY_CRITICAL<$BATTERY_OFF or die;
$BATTERY_OFF+1==$BATTERY_ON or die;

my($powerstation,$account,$pwd);
my $fn=$ENV{"HOME"}."/.goodwe.pl";
open F,$fn or die "$fn: $!\n";
(my $F=do { local $/; <F>; }) or die "read $fn: $!\n";
close F or die "close $fn: $!\n";
eval $F;
$powerstation&&$account&&$pwd or die $fn.': need $powerstation $account $pwd'."\n";

sub elapsednl($) {
  my($t0)=@_;
  printf " %.2fs\n",time()-$t0;
}

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
  sub check($$;$$) {
    my($res,$msg,@msg2)=@_;
    die $res->as_string() if !$res->is_success();
    my $json=JSON::decode_json($res->content());
    die "res hasError" if $json->{"hasError"};
    do { return undef if $_&&$json->{"msg"} eq $_; } for @msg2;
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

  $api=undef;
  my $res2json=check($ua->post(
    "https://semsportal.com/api/v2/Common/CrossLogin",
    [
      "account"=>$account,
      "pwd"=>$pwd,
    ],
  ),"Successful","Email or password error.") or return;
  $token{$_}=$res2json->{"data"}->{$_} for qw(uid timestamp token);
  retoken();
  $api=$res2json->{"api"};
}

sub data() {
  for my $attempt (0..30) {
    if (!$api&&$attempt==0) {
      print "initial login..." if !$api;
      my $t0=time();
      relogin();
      print ", failed" if !$api;
      elapsednl $t0;
    }
    if ($api) {
      my $res3json=check($ua->post(
	"${api}v2/PowerStation/GetMonitorDetailByPowerstationId",
	[
	  "powerStationId"=>$powerstation,
	],
      ),"success","The authorization has expired, please log in again.","No access, please log in.");
      return $res3json->{"data"} if $res3json;
      print "request on attempt $attempt failed";
    } else {
      print "will retry login";
    }
    if ($attempt) {
      print ", sleeping";
      sleep 30;
    }
    print ", relogging in";
    my $t0=time();
    relogin();
    print ", failed" if !$api;
    elapsednl $t0;
  }
  die "login failed";
}

sub retry($) {
  my($func)=@_;
  for my $attempt (0..1000000) {
    print "retry attempt $attempt...\n" if $attempt;
    $@=undef;
    my $retval=eval { &{$func}(); };
    return $retval if !$@;
    warn "failure: $@\n";
  }
}

sub data_retried() {
  print "goodwe fetch...\n";
  my $t0=time();
  my $data=retry \&data;
  print "goodwe fetch done";
  elapsednl $t0;
  return $data;
}

print "initial tesla fetch...";
my $t0=time();
my $car=Tesla::Vehicle->new(
  "auto_wake"=>1,
  # We do our own $car->api_cache_clear().
  "api_cache_persist"=>1,
);
elapsednl $t0;

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
    $rhs.=$suffixr{$cmd}//"" if $rhs;
  }
  say join(" ",$cmd,map $_//"undef",@args).($suffixl{$cmd}//"").": $rhs";
  return $rhs;
}

sub print_timestamp() {
  my $now=DateTime->now();
  $now->set_time_zone("local");
  print $now->iso8601().$now->time_zone_short_name()."\n";
}

if (@ARGV>=1&&$ARGV[0] eq "--calibrate") {
  shift;
  for my $amps (@ARGV) {
    $car->api_cache_clear;
    my $charging_state=$car->charging_state;
    print "charging_state=$charging_state\n";
    $car->charging_state eq "Complete" or die "!Complete";
    sub load_get() {
      my $data=data_retried();
      my $load=$data->{"powerflow"}{"load"};
      $load=~s/^(\d+(?:[.]\d+)?)[(]W[)]$/$1/ or die "load=<$load>!=\\d(W)";
      return $load;
    }
    my $load0=load_get();
    my $t0=time();
    print_timestamp();
    my $battery_level=$car->battery_level;
    print "battery_level=$battery_level\n";
    die "!(50<=battery_level<=90)" if $battery_level<50||$battery_level>90;
    my $soc=$battery_level+3;
    die "!(50<=soc<=90)" if $soc<50||$soc>90;
    my $charge_current_request=$car->charge_current_request;
    print "charge_current_request=$charge_current_request\n";
    $amps==$charge_current_request or cmd "charge_amps_set",$amps or die;
    my $charge_limit_soc=$car->charge_limit_soc;
    print "charge_limit_soc=$charge_limit_soc\n";
    $charge_limit_soc==$soc or cmd "charge_limit_set",$soc or die;
    sub load_wait($$) {
      my($sub,$expect)=@_;
      my $waited=0;
      while (1) {
	my $load=load_get();
	print "load=$load expecting $expect waited ${waited}s\n";
	# sometimes $load==0
	return $load if $load&&&{$sub}($load);
	my $slept=sleep 15;
	next if ($waited+=$slept)<10*60;
	cmd "charge_limit_set",50;
	die "Timeout $waited seconds waiting for increased load";
      }
    }
    # FIXME: $car->charger_phases
    my $expected=($amps*3*230)/2;
    my $compare=$load0+$expected;
    my $load1=load_wait sub { my($load)=@_; return $load>$compare; },$compare;
    my $t1=time();
    print_timestamp();
    cmd "charge_limit_set",50 or die "Cannot stop charging";
    # $load1-$expected does not work well, there is some residual
    # RESULT:  4A:   365 (100s)  3380 ( +3014 vs. 0) ( 83s)   854( +489 vs. 0):  2770 (1 vs. avg(0 2))
    $compare=$load0+100;
    my $load2=load_wait sub { my($load)=@_; return $load<$compare; },$compare;
    my $t2=time();
    print_timestamp();
    $charging_state=$car->charging_state;
    print "charging_state=$charging_state\n";
    $car->charging_state eq "Complete" or die "!Complete";
    my $diff10=$load1-$load0;
    my $diff102=$load1-($load0+$load2)/2;
    printf "RESULT: %2dA: %5d (%3ds) %5d (%+6d/%2dA=%+4d vs. 0) (%3ds) %5d(%+6d vs. 0): %5d/%2dA=%3d (1 vs. avg(0 2))\n",
      $amps,$load0,$t1-$t0,$load1,$diff10,$amps,$diff10/$amps,$t2-$t1,$load2,$load2-$load0,$diff102,$amps,$diff102/$amps;
  }
  print "done\n";
  exit 0;
}
die "$0: [--calibrate]\n" if @ARGV;

sub amps_to_watt($) {
  my($amps)=@_;
  die $amps if $amps<1;
  die $amps if $amps!=int($amps);
  return $amps*($WATT_PER_AMP_1+($WATT_PER_AMP_TOP-$WATT_PER_AMP_1)*($amps-1)/($AMP_TOP-1));
}
sub watt_to_amp($$) {
  my($watt,$amp_top)=@_;
  for my $amps (reverse 1..$amp_top) {
    return $amps if $watt>=amps_to_watt $amps;
  }
  return 0;
}

my $tesla_timestamp;
while (1) {
  print_timestamp();
  $tesla_timestamp||=time();
  my($battery_level,$charge_limit_soc,$charging_state,$charge_amps);
  print "tesla fetch";
  my $t0=time();
  retry sub {
    $battery_level=$car->battery_level;
    print ".";
    $charge_limit_soc=$car->charge_limit_soc;
    print ".";
    $charging_state=$car->charging_state;
    print ".";
    $charge_amps=$car->charge_amps;
  };
  elapsednl $t0;
  print "battery_level=$battery_level\n";
  print "charge_limit_soc=$charge_limit_soc\n";
  print "charging_state=$charging_state\n";
  die "Battery $battery_level<$BATTERY_CRITICAL=BATTERY_CRITICAL" if $battery_level<$BATTERY_CRITICAL;
  die "Battery $battery_level>$BATTERY_ON=BATTERY_ON" if $battery_level>$BATTERY_ON;
  die "Unexpected charge_limit_soc=$charge_limit_soc!=$BATTERY_ON=BATTERY_ON&&!=$BATTERY_OFF=BATTERY_OFF"
    if $charge_limit_soc!=$BATTERY_ON&&$charge_limit_soc!=$BATTERY_OFF;
  my $battery_on=$charge_limit_soc==$BATTERY_ON;
  die "Charging not reduced $charge_amps!=$CHARGE_AMPS=CHARGE_AMPS" if $charge_amps!=$CHARGE_AMPS;
  my $charging=$charging_state eq "Charging";
  die "Charging $charging_state not expected" if $charging_state!~/^(?:Charging|Complete)$/; #(?:Stopped|Disconnected)?
  my $wanted;
  my $sleep;
  my $hour=(localtime)[2];
  my $day=$hour>=6&&$hour<18;
  print "day=".($day?1:0)."\n";
  if ($battery_level>=$BATTERY_ON&&!$charging) {
    $wanted=0;
    $sleep=$TESLA_TIMEOUT_NOT_CHARGING;
    print "kept no charging as battery_level=$battery_level>=$BATTERY_ON=BATTERY_ON\n";
  } else {
    my $data=data_retried();
    my $pmeter=$data->{"inverter"}[0]{"invert_full"}{"pmeter"};
    die Dumper $data."\n!pmeter" if !defined $pmeter;
    $pmeter=sprintf "%+d",$pmeter;
    print "pmeter=$pmeter\n";
    if ($charging) {
      my $limit=$CHARGE_AMPS*230*3*($SAFETY_RATIO_SMALLER-1);
      $wanted=$pmeter>$limit;
      if (!$battery_on) {
	print "warning: Charging despite not wanting to!\n";
      } elsif (!$wanted) {
	print "stopping charging as pmeter=$pmeter<=$limit=limit\n";
      } else {
	print "kept charging as pmeter=$pmeter>$limit=limit\n";
      }
      $sleep=15;
    # !$charging&&$battery_level<$BATTERY_ON
    } elsif ($battery_on) {
      my $limit=$CHARGE_AMPS*230*3*$SAFETY_RATIO_SMALLER;
      $wanted=$pmeter>$limit;
      if (!$wanted) {
	print "stopped Tesla-unfulfilled desire to charge as pmeter=$pmeter<=$limit=limit\n" if !$wanted;
      } else {
	print "kept Tesla-unfulfilled desire to charge as pmeter=$pmeter>$limit=limit\n";
      }
      $sleep=60;
    } else { # $battery_off
      my $limit=$CHARGE_AMPS*230*3*$SAFETY_RATIO_BIGGER;
      $wanted=$pmeter>$limit;
      if ($wanted) {
	print "started Tesla-unfulfilled desire to charge as pmeter=$pmeter>$limit=limit\n";
      } else {
	print "kept no desire to charge as pmeter=$pmeter<=$limit=limit\n";
      }
      $sleep=$wanted?60:($day?5*60:60*60);
    }
  }
  print "wanted=".($wanted?1:0)." sleep=$sleep\n";
  $wanted=$wanted?$BATTERY_ON:$BATTERY_OFF;
  if ($wanted!=$charge_limit_soc) {
    $tesla_timestamp=undef;
    my $t0=time();
    retry sub {
      #warn "calling api_cache_clear";
      $car->api_cache_clear;
      #warn "calling api_cache_clear done";
      cmd "charge_limit_set",$wanted or die;
    };
    print "cmd";
    elapsednl $t0;
    $sleep=60;
  }
  print "sleep=$sleep\n";
  my $slept=sleep $sleep;
  warn "slept=$slept!=$sleep=sleep" if $slept!=$sleep;
  my $age=int(time()-$tesla_timestamp) if $tesla_timestamp;
  my $limit=($charging?$TESLA_TIMEOUT_CHARGING:$TESLA_TIMEOUT_NOT_CHARGING)-10;
  if ($age&&$age<$limit) {
    print "tesla data is still valid, age=$age<$limit=limit\n";
  } else {
    print "tesla data has expired, age=".(!defined $age?"undef":$age).">=$limit=limit\n";
    $car->api_cache_clear;
    $tesla_timestamp=undef;
  }
}
