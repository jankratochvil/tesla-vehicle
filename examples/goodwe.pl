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
use List::Util qw(min max);
require Geo::Location::TimeZone;
require DateTime::Event::Sunrise;
$|=1;

my $HOME_LAT;
my $HOME_LON;
my $HOME_DISTANCE=10; # measured 7.58
my $BATTERY_CRITICAL=45;
my $BATTERY_LOW=50;
my $BATTERY_HIGH=51;
# battery_level=50%
# charge_limit_soc=51% charge_amps=3A charger_phases=3 charge_port_latch=Engaged charging_state=Complete
my $BATTERY_HIGH_REQUEST=$BATTERY_HIGH+1;
my $SAFETY_RATIO_BIGGER=1.3;
my $SAFETY_RATIO_SMALLER=1.1;
my $TESLA_TIMEOUT_CHARGING=60;
my $TESLA_TIMEOUT_NOT_CHARGING=12*60*60;
my @TESLA_AWAKE_AT=(); # if Tesla gets each day awake at some specific times anyway
my $WATT_PER_AMP_1=770;
my $AMP_TOP=16;
my $WATT_PER_AMP_TOP=733;
my $TZ;
my $VOLTS=230; # FIXME

$BATTERY_CRITICAL<$BATTERY_LOW or die;
$BATTERY_LOW<$BATTERY_HIGH or die;
$BATTERY_HIGH<=$BATTERY_HIGH_REQUEST or die;
50<=$BATTERY_LOW or die; # =="BATTERY_LOW_REQUEST"
$BATTERY_HIGH_REQUEST<=100 or die;

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

sub check($$;$$) {
  my($res,$msg,@msg2)=@_;
  die $res->as_string() if !$res->is_success();
  my $json=JSON::decode_json($res->content());
  die "res hasError" if $json->{"hasError"};
  do { return undef if $_&&$json->{"msg"} eq $_; } for @msg2;
  die "res msg '".$json->{"msg"}."'!='$msg'" if $json->{"msg"} ne $msg;
  return $json;
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
  my sub retoken() {
    $ua->default_header("Token"=>JSON::encode_json(\%token));
  }
  retoken();

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

sub retry($;$) {
  my($func,$retries)=@_;
  $retries//=1000000;
  for my $attempt (0..$retries) {
    print "retry attempt $attempt of $retries...\n" if $attempt;
    $@=undef;
    my $retval=eval { &{$func}(); };
    return $retval if !$@;
    warn "failure: $@\n";
  }
  return undef;
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

sub print_timestamp(;$$) {
  my($nowparam,$offset)=@_;
  $nowparam||=DateTime->now();
  my $now=$nowparam->clone();
  $now->set_time_zone("local");
  $now->add("seconds"=>$offset) if $offset;
  if ($TZ) {
    my $nowtz=$nowparam->clone();
    $nowtz->set_time_zone($TZ);
    $nowtz->add("seconds"=>$offset) if $offset;
    print $nowtz->iso8601().$nowtz->time_zone_short_name()." " if $now->offset()!=$nowtz->offset();
  }
  print $now->iso8601().$now->time_zone_short_name()."\n";
}

if (@ARGV>=1&&$ARGV[0] eq "--calibrate") {
  shift;
  for my $amps (@ARGV) {
    my $charge_current_request_max=$car->charge_current_request_max;
    die "amps=$amps>$charge_current_request_max=charge_current_request_max" if $amps>$charge_current_request_max;
    $car->api_cache_clear;
    my $charging_state=$car->charging_state;
    print "charging_state=$charging_state\n";
    $car->charging_state eq "Complete" or die "!Complete";
    my sub load_get() {
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
    my $charge_amps=$car->charge_amps;
    print "charge_amps=$charge_amps\n";
    my $charge_current_request=$car->charge_current_request;
    print "WARNING: charge_current_request=$charge_current_request != $charge_amps=charge_amps\n" if $charge_current_request!=$charge_amps;
    $amps==$charge_amps or cmd "charge_amps_set",$amps or die;
    my $charge_limit_soc=$car->charge_limit_soc;
    print "charge_limit_soc=$charge_limit_soc\n";
    $charge_limit_soc==$soc or cmd "charge_limit_set",$soc or die;
    my sub load_wait($$) {
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
    my $expected=($amps*$car->charger_phases*$VOLTS)/2;
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
  return 0 if $amps==0;
  die $amps if $amps<1;
  die $amps if $amps!=int($amps);
  return int($amps*($WATT_PER_AMP_1+($WATT_PER_AMP_TOP-$WATT_PER_AMP_1)*($amps-1)/($AMP_TOP-1)));
}
sub watt_to_amp($$) {
  my($watt,$amp_top)=@_;
  for my $amps (reverse 1..$amp_top) {
    return $amps if $watt>=amps_to_watt $amps;
  }
  return 0;
}
sub print_amps_to_watt($) {
  my($amp_top)=@_;
  print join(" ",map "${_}A=".amps_to_watt($_)."W",0..$amp_top)."\n";
}

sub distance($$) {
  my($lat,$lon)=@_;
  # https://sciencing.com/convert-distances-degrees-meters-7858322.html
  return sprintf "%f",sqrt(($lat-$HOME_LAT)**2+($lon-$HOME_LON)**2)*111139;
}

my $tesla_timestamp;
my $geo=Geo::Location::TimeZone->new();
while (1) {
  print_timestamp();
  $tesla_timestamp||=time();
  my($battery_level,$charge_limit_soc,$charging_state,$charge_amps,$charge_current_request,$charge_actual_current,$latitude,$longitude,$charge_port_latch,$charger_phases);
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
    print ".";
    $charge_current_request=$car->charge_current_request;
    print ".";
    $charge_actual_current=$car->charge_actual_current;
    print ".";
    $latitude=$car->latitude;
    print ".";
    $longitude=$car->longitude;
    print ".";
    $charge_port_latch=$car->charge_port_latch;
    print ".";
    $charger_phases=$car->charger_phases;
  };
  elapsednl $t0;
  print "latitude,longitude=$latitude,$longitude";
  my $old_TZ=$TZ;
  $TZ=$geo->lookup("lat"=>$HOME_LAT,"lon"=>$HOME_LON);
  print ";TZ=$TZ";
  my $distance=distance $latitude,$longitude;
  my $at_home=$distance<$HOME_DISTANCE?1:0;
  print ";distance=$distance,max=$HOME_DISTANCE,at_home=$at_home";
  my $sunriseloc=DateTime::Event::Sunrise->new(
    "latitude" =>$HOME_LAT,
    "longitude"=>$HOME_LON,
  );
  my $nowtz=DateTime->now(
    "time_zone"=>$TZ,
  );
  my $sunrise=$sunriseloc->sunrise_datetime($nowtz);
  my $sunset =$sunriseloc-> sunset_datetime($nowtz);
  my sub day() {
    return $nowtz->is_between($sunrise,$sunset);
  }
  my $day=day();
  print ";day=".($day?1:0)."\n";
  print_timestamp() if $TZ ne ($old_TZ||"");
  print "sunrise: "; print_timestamp($sunrise);
  print "sunset : "; print_timestamp($sunset );
  print "battery_level=$battery_level%\n";
  print "charge_limit_soc=$charge_limit_soc% charge_amps=${charge_amps}A charger_phases=$charger_phases charge_port_latch=$charge_port_latch charging_state=$charging_state\n";
  print "WARNING: charge_current_request=$charge_current_request!=$charge_amps=charge_amps\n" if $charge_current_request!=$charge_amps;
  die "Battery $battery_level<$BATTERY_CRITICAL=BATTERY_CRITICAL" if $battery_level<$BATTERY_CRITICAL;
  #die "Battery $battery_level>$BATTERY_HIGH=BATTERY_HIGH" if $battery_level>$BATTERY_HIGH;
  die "Unexpected BATTERY_LOW=$BATTERY_LOW!<=charge_limit_soc=$charge_limit_soc!<=$BATTERY_HIGH_REQUEST=BATTERY_HIGH_REQUEST"
    if $charge_limit_soc<$BATTERY_LOW||$charge_limit_soc>$BATTERY_HIGH_REQUEST;
  my $battery_high=$battery_level>=$BATTERY_HIGH;
  my $charging=$charging_state eq "Charging";
  die "Charging $charging_state not expected" if $charging_state!~/^(?:Charging|Complete)$/; #(?:Stopped|Disconnected)?
  print "WARNING: !charging&&charge_actual_current=$charge_actual_current!=0" if !$charging&&$charge_actual_current;
  # FIXME WARNING: charge_actual_current=0!=5=charge_amps
  #print "WARNING: charge_actual_current=$charge_actual_current!=$charge_amps=charge_amps\n" if $charging&&$charge_actual_current!=$charge_amps;
  print "WARNING: charge_actual_current=$charge_actual_current!=0\n" if $charge_actual_current;
  # $charge_amps->$charge_actual_current? but $charge_actual_current==0
  my $amps_old=$charging?$charge_amps:0; # FIXME:simplify?
  $charge_port_latch=0 if $charge_port_latch ne "Engaged";
  my $wanted;
  my $sleep;
  if (!$at_home) {
    $wanted=0;
    $sleep=max(60,$distance/1000/180*3600);
    print "Not at home.\n";
  } elsif (!$charge_port_latch) {
    $wanted=0;
    $sleep=60;
    print "At home but not plugged.\n";
  } elsif ($battery_level>=$BATTERY_HIGH&&!$charging) {
    $wanted=0;
    $sleep=$TESLA_TIMEOUT_NOT_CHARGING;
    print "kept no charging as battery_level=$battery_level>=$BATTERY_HIGH=BATTERY_HIGH\n";
  } else {
    if ($charging) {
      if ($battery_high) {
	$wanted=0;
	print "Still charging despite it already has the battery level, stopping charging.\n";
      } else {
	$wanted=1;
      }
      $sleep=60;
    # !$charging&&$battery_level<$BATTERY_HIGH
    } elsif ($battery_high) {
      $wanted=0;
      $sleep=60;
      print "Battery is high.\n";
    } else { # $battery_low
      $wanted=1;
      print "Battery is low.\n";
      $sleep=60;
    }
  }
  print "wanted=$wanted sleep=$sleep\n";
  if ($at_home&&$charge_port_latch) {
    my $pv=0;
    if ($wanted) {
      my $data=data_retried();
      $pv=$data->{"powerflow"}{"pv"};
      $pv=~s/^(\d+(?:[.]\d+)?)[(]W[)]$/$1/ or die "pv=<$pv>!=\\d(W)";
      my $load=$data->{"powerflow"}{"load"};
      $load=~s/^(\d+(?:[.]\d+)?)[(]W[)]$/$1/ or die "load=<$load>!=\\d(W)";
      my $inverter=$data->{"inverter"}[0] or die Dumper $data."\n!inverter";
      my $soc=$inverter->{"soc"};
      $soc=~s/^(\d+)[%]$/$1/ or die "soc=<$soc>!=\\d%";
      my $amps_old_watt=amps_to_watt $amps_old;
      my $amps_old_watt_valid=$amps_old_watt<=$load?1:0;
      print "pv=${pv}W load=${load}W amps_old=${amps_old}A=${amps_old_watt}W amps_old_watt_valid=$amps_old_watt_valid soc=${soc}%\n";
      $amps_old_watt=0 if !$amps_old_watt_valid;
      my $bms_status=$inverter->{"bms_status"} or die Dumper $data."\n!bms_status";
      print "bms_status=$bms_status\n";
      my $bms_status_re="(?:StandbyOfBattery|ChargingOfBattery|DischargingOfBattery)"; # FIXME: when ""?
      $bms_status=~/^$bms_status_re$/o or print "WARNING: bms_status=$bms_status!~/$bms_status_re/\n";
      my $battery_power=$inverter->{"battery_power"};
      print "battery_power=${battery_power}W";
      $battery_power=int($battery_power);
      print " -> ${battery_power}W\n";
      my $pmeter=$inverter->{"invert_full"}{"pmeter"};
      die Dumper $data."\n!pmeter" if !defined $pmeter;
      $pmeter=sprintf "%+d",$pmeter;
      my $pmeter_real=$pmeter+$amps_old_watt-$battery_power;
      print "pmeter_real=${pmeter_real}W pmeter=${pmeter}W battery_power(-=usable=charge,+=problem=discharge)=${battery_power}W\n";
      print_amps_to_watt $car->charge_current_request_max;
      my $pmeter_real_low =int($pmeter_real/$SAFETY_RATIO_BIGGER );
      my $pmeter_real_high=int($pmeter_real/$SAFETY_RATIO_SMALLER);
      my $wanted_low =watt_to_amp $pmeter_real_low ,$car->charge_current_request_max;
      my $wanted_high=watt_to_amp $pmeter_real_high,$car->charge_current_request_max;
      $wanted=$amps_old<$wanted_low||$amps_old>$wanted_high?$wanted_low:$amps_old;
      my $wanted_watt=amps_to_watt $wanted;
      print $amps_old==$wanted?"kept  ":"CHANGE";
      print ": pmeter_real=${pmeter_real}W /$SAFETY_RATIO_BIGGER=${pmeter_real_low}W->${wanted_low}A ";
      print(($amps_old<$wanted_low ?"!":"")."<=");
      print " old=${amps_old_watt}W=${amps_old}A ";
      print(($amps_old>$wanted_high?"!":"")."<=");
      print " /$SAFETY_RATIO_SMALLER=${pmeter_real_high}W->${wanted_high}A";
      print " -> wanted=${wanted_watt}W=${wanted}A";
      if ($amps_old!=$wanted) {
	print " ";
	print_timestamp();
      } else {
	print "\n";
      }
    } elsif ($amps_old) {
      print "Stopping charging.\n";
    }
    $sleep=max($sleep,$day?($pv?60:5*60):60*60) if !$amps_old&&!$wanted;
    my $wanted_soc=$wanted?$BATTERY_HIGH_REQUEST:$BATTERY_LOW;
    $wanted||=$car->charge_current_request_max;
    if ($wanted_soc!=$charge_limit_soc||$wanted!=$charge_amps) {
      $tesla_timestamp=undef;
      my $t0=time();
      retry sub {
	$car->api_cache_clear;
	# some Perl bug: It does not work without the references.
	my sub change_limit_soc($$) {
	  my($charge_limit_soc,$wanted_soc)=@_;
	  $charge_limit_soc==$wanted_soc or cmd "charge_limit_set",$wanted_soc or die;
	  $charge_limit_soc=$wanted_soc;
	}
	my sub change_amps($$) {
	  my($charge_amps,$wanted)=@_;
	  $charge_amps==$wanted or cmd "charge_amps_set",$wanted or die;
	  $charge_amps=$wanted;
	}
	if ($wanted>$charge_amps) {
	  change_limit_soc($charge_limit_soc,$wanted_soc);
	  change_amps($charge_amps,$wanted);
	} else {
	  change_amps($charge_amps,$wanted);
	  change_limit_soc($charge_limit_soc,$wanted_soc);
	}
	$car->api_cache_clear;
	print "charge_limit_soc=";
	$charge_limit_soc=$car->charge_limit_soc;
	print "$charge_limit_soc\n";
	print "charge_amps=";
	$charge_amps=$car->charge_amps;
	print "$charge_amps\n";
	my @err;
	push @err,"wanted_soc=$wanted_soc!=$charge_limit_soc=charge_limit_soc" if $wanted_soc!=$charge_limit_soc;
	push @err,"wanted=$wanted!=$charge_amps=charge_amps" if $wanted!=$charge_amps;
	die "tesla settings failed, retrying: ".join(" && ",@err)."\n" if @err;
	return 1;
      },3 or do { cmd "charge_limit_set",$BATTERY_LOW or warn "shutdown battery"; die "failed change"; };
      print "cmd";
      elapsednl $t0;
      $sleep=60;
    }
  }
  print "sleep=$sleep\n";
  my sub seconds_since_midnight($) {
    my($now)=@_;
    return $now->hour()*3600+$now->minute()*60+$now->second();
  }
  my @awakes;
  push @awakes,seconds_since_midnight($sunrise);
  push @awakes,@TESLA_AWAKE_AT;
  { my $seconds_since_midnight=seconds_since_midnight($nowtz);
    for my $awake (@awakes) {
      $awake+=24*60*60 if $awake<$seconds_since_midnight;
      my $sleep_new=$awake-$seconds_since_midnight;
      $sleep_new>=0 or die;
      if ($sleep_new<$sleep) {
	$sleep=$sleep_new;
	print "sleep=sleep_new=$sleep as a wakeup is earlier.\n";
	$tesla_timestamp=undef;
      } else {
	print "sleep_new=$sleep_new but sleep is already earlier.\n";
      }
    }
  }
  print "Going to awake at: ";
  print_timestamp($nowtz,$sleep);
  my $slept=sleep $sleep;
  warn "slept=$slept!=$sleep=sleep" if $slept!=$sleep;
  my $age=int(time()-$tesla_timestamp) if $tesla_timestamp;
  # FIXME: Parked after driving.
  my $limit=($charging?$TESLA_TIMEOUT_CHARGING:$TESLA_TIMEOUT_NOT_CHARGING)-10;
  if (day()&&$day!=day()) {
    print "We have a new day, clearing tesla data.\n";
    $age=undef;
  }
  if ($age&&$age<$limit) {
    print "tesla data is still valid, age=$age<$limit=limit\n";
  } else {
    print "tesla data has expired, age=".(!defined $age?"undef":$age).">=$limit=limit\n";
    $car->api_cache_clear;
    $tesla_timestamp=undef;
  }
}
