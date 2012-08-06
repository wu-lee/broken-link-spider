#!/usr/bin/perl -w
use strict;
use LWP::UserAgent;
use HTML::LinkExtractor;
use Data::Dumper;
use IO::File;
use POSIX qw(strftime);
use Cwd qw(getcwd);
use Getopt::Long;

######################################################################
# Global variables.

my %unvisited;
my %visited;
my %referrers;
my @broken;
my @exclusions; # regexps for links to ignore
my $delay = 0; # min seconds of delay beween each URL downloaded.
my $timestamp = timestamp();
my $logfile = "log.$timestamp.txt";
my $ua = LWP::UserAgent->new;
$ua->cookie_jar({ file => getcwd . ".cookies.txt" });
push @{ $ua->requests_redirectable }, qw(HEAD POST GET);

my $lx = HTML::LinkExtractor->new();


######################################################################
# Functions

# trace() (and associated variables)
{
    die "Couldn't open logfile $logfile: $!"
        unless my $log = IO::File->new(">$logfile");

    # These set the log level. Low numbers are more verbose.
    my $loglevel = 0;  # What goes into the log
    my $displevel = 1; # What get printed

    # trace @strings
    #
    # Logfile trace function, prints to the screen and/or the logfile
    sub trace
    {
        my $level = shift;
        print @_
            if $level >= $displevel;
        print {$log} @_
            if $level >= $loglevel;
    }

    sub debug   { trace 0, @_ }
    sub info    { trace 1, @_ }
    sub warning { trace 2, @_ }
    sub error   { trace 3, @_ }
    sub report  { trace 4, @_ }
}


sub timestamp {
    return strftime "%F-%H:%M:%S", localtime;
}

# This decides if a link should be spidered or just validated
sub is_in_scope {
    my $url = shift;
    foreach my $exclusion (@exclusions) {
        return 
            if $url =~ /$exclusion/;
    }
    return 1;
}

# This decides if a link should be validated or not
sub is_readable {
    shift =~ /^https?:/;
}

sub canonical {
    my ($url, $base) = @_;
    $url =~ s!#[^/]*$!!; # remove section links.
    $url = URI->new($url);
    $url = $url->abs($base)
        if $base;
    $url = $url->canonical;
    return $url;
}

######################################################################
# Option processing and configuration

my $usage = <<USAGE;
This script spiders web links, starting from URLs list as commandline
arguments, or if the first argument is a filename, URLs listed in that
file, one per line.

The first URL is considerd the 'base' and the spider will not search pages
which lie outside this root URL.  The others are just used as extra starting
points.

Forms will not be submitted and javascript links are not followed - so
for example javascript-powered navigation mechanisms will not be
tested.  This can be worked around by supplying extra seed urls.

The speed of URL visiting is controlled by the internally defined
variable \$delay.

Progress is output to the console, and additionally written to a
logfile named 'log.YY-MM-DD_hh_mm.txt' where YY, MM, DD, hh and mm are
the current year, month, day, hour and minute, respectively.

USAGE

debug "command line:\n$0 @ARGV\n\n";

my %opt;
die "Failed to parse options:\n$usage"
    unless GetOptions(
        \%opt, 
        qw(help exclude=s@)
    );


my @seeds = map { canonical $_ } @ARGV;
die "No seed URLs specified\n"
    unless @seeds;

# Ad an exclusion pattern for any URL which isn't a seed or some
# extension of one.
my $seeds_matcher = join "|", map { "\Q$_\E" } @seeds;
@exclusions = (qr/^(?!$seeds_matcher)/, @{ $opt{exclude} || [] });


# First get the seed urls specified, either from the command line
# or from the config file ...

if ($seeds[0] !~ /^http:/) {
    # perhaps this is a config file?
    die "Argument is neither a base URL nor a valid config file\n"
        unless -f $seeds[0];

    open my $config, "<", "$seeds[0]"
        or die "Couldn't open confile file $seeds[0]: $!\n";
    @seeds = <$config>;
    close $config;

    chomp @seeds;
    print "interpreting argument 1 as config file and ignoring spurious arguments\n"
        if @seeds > 1;
}

print "using the seed URLs:\n", join "\n",@seeds;
print "\n\n";

######################################################################

# Mark all the seed URLs unvisited, to kick things off
$unvisited{$_}++
    foreach @seeds;



# This loops over the unvisited urls, adding more as they're found,
# and removing them when visited.
while(%unvisited) {
    my @keys = keys %unvisited;
    info timestamp ." - pages pending: ".@keys."\n";

    foreach my $url (@keys) {
        # Remove this link from the 'unvisited' list
        delete $unvisited{$url};

        # And add it to the 'visited' list, unless it's there already,
        # in which case we can skip it
        next
            if $visited{$url}++;

        # We don't validate non-http links (i.e. ftp://, mailto: etc.)
        debug  "skipping (not readable): $url\n" and next
            unless is_readable $url;

        # Pause so as not to overload the server
        sleep $delay
            if $delay;

        # Get the page - list the link as broken if this fails
        # if the page is in scope, spider its links
        debug "--------\n";
        my $is_in_scope = is_in_scope $url;
        my $response;
        eval {
            my $method = $is_in_scope? 'GET' : 'HEAD';
            my ($referrer) = @{$referrers{$url} || ['none']};
            my $pending = keys %unvisited;
            info "${method}-ing $url from $referrer ($pending pending)";
            my $request = HTTP::Request->new($method => $url);
            $response = $ua->request($request);
        }
            or do { # catch exceptions - something unusal is wrong
                push @broken, {
                     code => -1,
                     message => $@,
                     url => $url,
                };
                error  "exception whilst getting $url: $@\n";
                next;
            };
        
        my $code = $response->code;
        info " OK ($code)\n";
        
        if (!$response->is_success) {
            push @broken, {
                code => $code,
                message => $response->message,
                url => $url,
            };
        }            

        next
            unless $is_in_scope;

        next
            unless $response->content_type =~ m{^(text/html)$};

        # Gather links in page
        my $links;
        eval {
            my $content = $response->content;
            $lx->parse(\$content);
            $links = $lx->links; 
        }
            or do {
                # If $links is undefined, either there was an exception or 
                # there are no links parsed for some reason.  Either way 
                # we#re done with this page.
                error "exception whilst parsing content of $url: $@"
                    if $@;
                next;
            };

 
        # Now process these links
        foreach my $link (@$links) {
            # Get the URL, skip it if it isn't a href or src
            my $href = $link->{href} || $link->{src};
            next
                unless $href;

            # Convert the URL into a canonical URL
            $href = canonical $href, $response->base;

            # Add links to the list of links still to follow
            push @{ $referrers{$href} }, $url;

#            debug  Dumper $link;#
            debug  "found: $href ";
            debug ("(visited)\n") and next
                if $visited{$href};
            ++$unvisited{$href};
            debug  "\n";
        }

        debug  "\n";
    }
}

info timestamp. " - Done, no more links\n";

# Convert the broken list, with hindsight, to a list
# of pages linking to broken ones.
my %defects;
foreach my $breakage (@broken) {
    my ($url, $code) = @$breakage{qw(url code)};
    my $referrers = $referrers{$url};
    $defects{$_}{$url}{$code}++
        foreach @$referrers;
}


if (%defects) {
    foreach my $page (sort keys %defects) {
        report  "Links broken in $page:\n";
        my $defects = $defects{$page};
        foreach my $link (sort keys %$defects) {
            my $errors = $defects->{$link};
            foreach my $code (sort keys %$errors) {
                my $count = $errors->{$code};
                report sprintf(
                    "%4d error #%d%s following %s\n",
                    $count,
                    $code,
                    ($count==1? '' : 's'),
                    $link,
                );
            }
        }
        report "\n";
    }
}
else {
    report "No broken links found\n";
}

info timestamp. " - Goodbye\n";
