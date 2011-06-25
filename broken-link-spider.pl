#!/usr/bin/perl -w
use strict;
use LWP::UserAgent;
use HTML::LinkExtractor;
use Data::Dumper;
use IO::File;
use Posix qw(strftime);

my %unvisited;
my %visited;
my %referrers;
my @broken;
my $links;
my $delay = 1; # min seconds of delay beween each URL downloaded.
my $time = strftime "%F-%H%M", localtime;
my $logfile = "log.$time.txt";


######################################################################

# Logfile trace function
{
    die "Couldn't open logfile $logfile: $!"
        unless my $log = IO::File->open(">$logfile");

    # These set the log level
    my $loglevel = 0;  # what goes into the log
    my $displevel = 1; # What get printed

    # This writes to the log
    sub trace
    {
        my $level = shift;
        print @_ 
            if $level >= $displevel;
        print {$log} @_
            if $level >= $loglevel;
    }
}

######################################################################

if (!@ARGV or $ARGV[0] =~ /^(--help|-h)$/) {
    die <<USAGE;
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
}

my @seeds = @ARGV;
die "No base URL specified\n"
    unless @seeds;


trace 0, "command line:\n$0 @ARGV\n\n";

# First get the seed urls specified, either from the command line
# or from the config file ...

if ($seeds[0] !~ /^http:/) {
    # perhaps this is a config file?
    die "Argument is neither a base URL nor a valid config file\n"
        unless -f $seeds[0];

    open my $config, "<", "$seeds[0]"
        or die "Couldn't open confile file $seeds[0]: $!\n";
    $seeds = <$config>; 
    close $config;

    chomp @seeds;
    print "interpreting argument 1 as config file and ignoring spurious arguments\n"
        if @seeds > 1;
}

my $base = shift @seeds;
print "using the base URL:\n$base\n";
if (@seeds) {
    print "using the seed URLs:\n", join "\n",@seeds;
}
else {
    print "no seed URLs";
}
print "\n\n";

######################################################################

# Mark all the seed URLs unvisited, to kick things off
$unvisited{$_}++
    foreach $base, @seeds;


######################################################################

# This defines the get_links sub plus some private globals
{
    my $ua = LWP::UserAgent->new;
    $ua->cookie_jar({ file => "$ENV{PWD}/.cookies.txt" });
    push @{ $ua->requests_redirectable }, 'POST';
    
    my $LX = HTML::LinkExtractor->new();
    
    # $content = get_page $url
    #
    # Retrieves the page from the url given.
    # if the link is broken, throws and exception
    sub get_page {
        my $url = shift;

        # Create a request
        my $req = HTTP::Request->new(GET => $url);
        
        # Pass request to the user agent and get a response back
        my $res = $ua->request($req);

        # Check the outcome of the response
        die "Failed to load $url: ", $res->status_line, "\n"
            unless $res->is_success;

        return $res->content;
    }

    # @links = get_links $page_content
    #
    # Returns a ref to an array of links.
    # $link = { href => $href, _TEXT => $text}
    sub get_links {
        my $content = shift;
        $LX->parse(\$content);
        return $LX->links;
    }
}

# This decides if a link should be spidered or just validated
sub is_in_scope {
    shift =~ /^$base/;
}

# This decides if a link should be validated or not
sub is_readable {
    shift =~ /^https?:/;
}


# This loops over the unvisited urls, adding more as they're found,
# and removing them when visited.
while(%unvisited) {
    my @keys = keys %unvisited;
    trace 1,  "pages pending: ".@keys."\n";

    foreach my $url (@keys) {
        # Remove this link from the 'unvisited' list
        delete $unvisited{$url};

        # And add it to the 'visited' list, unless it's there already,
        # in which case we can skip it
        next if $visited{$url}++;

        # We don't validate non-http links (i.e. ftp://, mailto: etc.)
        trace 0,  "skipping (not readable): $url\n" and next
            unless is_readable $url;

        # Pause so as not to overload the server
        sleep $delay
            if $delay;

        # Get the page - list the link as broken if this fails
        # if the page is in scope, spider its links
        trace 0, "--------\n";
        trace 1, "getting $url... ";
        eval {
            my $content = get_page $url;

            # We don't follow links outside of the base URL
#            trace 0,  "skipping (outside of base URL): $href\n";
            $links = is_in_scope($url)?
                get_links($content) : []; 
            1;
        }
        or do { # catch exceptions
            trace 1,  "FAILED:\n$@\n";
            push @broken, $url;
            next;
        }

        trace 1,  " OK\n";

        # Now process these links
        foreach my $link (@$links) {
            # Get the URL
            my $href = $link->{href} || $link->{src};
            next unless $href;

            # Convert the URL into a canonical URL
            $href = URI->new($href)->abs($url)->canonical;
            $href =~ s!#[^/]*$!!; # remove section links.

            # Add links to the list of links still to follow
            push @{ $referrers{$href} }, $url;

#            trace 0,  Dumper $link;#
            trace 0,  "found: $href ";
            trace 0, ("(visited)\n") and next
                if $visited{$href};
            ++$unvisited{$href};
            trace 0,  "\n";
        }
        
        trace 0,  "\n";
    }
}

trace 1,  "Done, no more links\n";

# Convert the broken list, with hindsight, to a list
# of pages linking to broken ones.
my %defects;
foreach my $link (@broken) {
    my $referrers = $referrers{$link};
    $defects{$_}{$link}++ foreach @$referrers;
}

foreach my $page (sort keys %defects) {
    trace 1,  "Links broken in $page:\n";
    my $defects = $defects{$page};
    foreach my $link (sort keys %$defects) {
        my $errors = $defects->{$link};
        foreach my $type (sort keys %$errors) {
            my $count = $errors->{$type};
            trace 1, sprintf("%4d error #%3ds following %s\n",
                             $count, $type, $link);
        }
    }
    trace 1,  "\n";
}

trace 1, "Goodbye\n";
