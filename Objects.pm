package DB::Objects;

use strict;
use warnings qw(all);
use vars qw($VERSION);

BEGIN {
    $VERSION=0.01;
}

###

package DB::Object;

use strict;
use warnings qw(all);

# Back-end methods
sub _blank {    # Default back-end for constructor
                # ARGS: $self, [$namespace,] @arglist
                # $namespace - Scalar (string) - Namespace of managing package for variables
                # @arglist   - Array (string) - List of variables to be registered as methods
    my $self=shift;
    my $package=
          (UNIVERSAL::isa($_[0],__PACKAGE__) && # Looks like a descendant
          shift) || caller; # Shift or autodetect namespace to register
    warn "Package $package not listed in registry"
        unless defined($self->{_REGISTRY}{$package});
    while (@_) {
        local $_=shift;
        $self->{$_}=undef;
        $self->{_REGISTRY}{_DATA}{$_}{source}=$package;
        $self->{_REGISTRY}{_DATA}{$_}{access}=1; # default to rw
    }
}

sub _register { # Default back-end for package registration
                # Call immediately after being bless()ed
    my $self=shift;
    my $package=caller;
    $self->{_REGISTRY}{$package}{prep}=0 unless (defined($self->{_REGISTRY}{$package}));
    return defined($self->{_REGISTRY}{$package});
}

sub _unregister{# Default back-end for package de-registration
                # If you wish to partially destruct an object, make sure to call this
                # from each namespace being removed from the object
    my $self=shift;
    my $package=caller;
    $self->_taint($package);
    undef $self->{_REGISTRY}{$package};
    return (!(defined($self->{_REGISTRY}{$package})));
}


sub _primary {  # Sets/detects whether a namespace contains the primary key
                # Used internally to assure that the primary key's namespace is always
                # in sync with the rest of the object
    my $self=shift;
    my $package=(UNIVERSAL::isa($_[0],__PACKAGE__) && shift) || caller;
    if ($_[0]) {$self->{_REGISTRY}{_PRIMARY}=$package;$self->_taint;}
    return $self->{_REGISTRY}{_PRIMARY};
}

sub _readonly { # Sets/detects whether a data mehod is tagged read-only
                # Used by AUTOLOAD to detect read-only method calls
    my $self=shift;
    my $package=(UNIVERSAL::isa($_[0],__PACKAGE__) && shift) || caller;
    my $var=shift;
    if (@_) {local $_=shift;$self->{_REGISTRY}{_DATA}{$var}{access}=$_ if (/[01]/);}
    return (!($self->{_REGISTRY}{_DATA}{$var}{access}) ||
            $self->{_REGISTRY}{_DATA}{$var}{source} eq $self->_primary);
}

sub _validate { # Marks a namespace as tied to the back-end database
                # Intended to be called on first refresh - Paired with _taint
    my $self=shift;
    my $package=shift || caller;
    $self->{_REGISTRY}{$package}{prep}=1;
    $self->_clean($package);
}

sub _taint {    # Marks a namespace as untied from the back-end database
                # Intended to be called on destruction only
    my $self=shift;
    my $package=shift || caller;
    $self->_dirty($package);
    $self->{_REGISTRY}{$package}{prep}=0;
}

sub _clean {    # Marks a namespace as in-sync with the back-end database
                # Intended to be called on all calls to add(), refresh() and update()
    my $self=shift;
    my $package=shift || caller;
    $self->{_REGISTRY}{$package}{dirty}=0;
}

sub _dirty {    # Marks a namespace as out-of-sync with the back-end databse
                # Intended to be called upon a write-access call to a class-method
    my $self=shift;
    my $package=shift || caller;
    $self->{_REGISTRY}{$package}{dirty}=1;
}

sub _vars {     # Returns a list of variables registered to a specific namespace
                # Used internally by default _refresh() and update() methods
    my $self=shift;
    my $package=shift || caller;
    my @vars = ();
    my @keys = keys(%{$self->{_REGISTRY}{_DATA}});
    foreach my $var(@keys) {
        push @vars,$var if $self->{_REGISTRY}{_DATA}{$var}{source} eq $package;
    }
    return @vars;
}

sub _refresh {  # Default back-end for refresh
                # Inherited classes should implement a custom _refresh()
                # Alternatively, the default _refresh may be used if a valid DBI connection
                # is set using $__PACKAGE__::dbh and the table is set to $__PACKAGE__::table
    my $self=shift;
    my $package=(UNIVERSAL::isa($_[0],__PACKAGE__) && shift) || caller;
    my @vars=$self->_vars($package);
    my $sth;
    {
        no strict 'vars';
        eval "\$sth=\$dbh->prepare_cached('SELECT \@vars FROM \$table WHERE (ID=?)');";
    }
    $sth->execute(@_) or return $self->blank;
    if ($sth->rows!=1) {
	$self->blank;
    } else {
	my $res=$sth->fetchrow_hashref;
	foreach my $var (@vars) {
	    $self->{$var}=$res->{$var};
	}
        $self->_validate;
    }
    $sth->finish;
    return $self;
}

sub AUTOLOAD {  # Default method call handler
                # Current support:
                #    * Read/Write registered methods from internal hash
    my $param;
    {
        no strict 'vars';
        $AUTOLOAD=~s/.*:://;
        $param=$AUTOLOAD;
    }
    if (UNIVERSAL::isa($_[0],__PACKAGE__)) { # Method call of a sub-class
        my $self=shift;
        if ($self->{_REGISTRY}{_DATA}{uc($param)}) { # Acceptable function call
            my $source=$self->{_REGISTRY}{_DATA}{uc($param)}{source};
            if (!($self->valid($source))) {
                $self->refresh($source);
            }
            if ((@_) && !($self->_readonly($source,$param))) { # Update rewriteable request
                $self->{uc($param)}=@_;
                $self->_taint;
            }
            return $self->{uc($param)};
        }
    }
}

sub new {       # Default constructor
                # Do not overload this unless you're SURE you know what you're doing
    my $self={ };
    my $proto=shift;
    my $class=ref($proto) || $proto;
    bless $self,$class;
    eval "foreach \$_ (\@".$class."::ISA) {eval \$_.\"::blank(\\\$self);\";}";
    $self->blank;
    if (@_) {
        eval ($self->_primary."::_refresh(\$self,@_);") if ($self->_primary);
	$self->_refresh(@_);
    }
    return $self;
}

sub clean {     # Returns true if namepace is in-sync with back-end database
                # Be sure to check for valid()ity BEFORE using this
    my $self=shift;
    my $package=shift || caller;
    return !($self->{_REGISTRY}{$package}{dirty});
}

sub valid {     # Returns true if namespace is tied and in-sync with back-end database
    my $self=shift;
    my $package=shift || caller;
    if (defined($self->_primary))
    {return ($self->{_REGISTRY}{$self->_primary}{prep} &&
             $self->clean($self->_primary) &&
             $self->{_REGISTRY}{$package}{prep} &&
             $self->clean($package))}
    else {return $self->{_REGISTRY}{$package}{prep} &&
                 $self->clean($package)};
}

sub blank {     # Default (abstract) blank method - used by the default constructor
                # This should be overridden by any inherited class that's meant to be useful
                # A typical blank() method should look like:
                #    sub blank {
                #        my $self=shift;
                #        $self->_register;
                #        $self->_blank("FOO", "BAR", ... , "LAST");
                #    }
    $_[0]->_register;
}

sub refresh {   # Default front-end for refresh
    my $self=shift;
    my $package=shift || caller;
    $self->_taint($package);
    eval $package."::_refresh(\$self,".$self->id.");";
    return $self->valid;
}

1;

__END__

=head1 NAME

DB::Objects - Perl extension to ease creation of database-bound objects

=head1 SYNOPSIS

  use DB::Objects;
  push @ISA, qw(DB::Object);

=head1 DESCRIPTION

Generic extension to ease creation of database-bound objects.

=head1 USAGE

This library is intended to be subclassed.  Please see the source code for preliminary
documentation.

=head1 AUTHOR AND COPYRIGHT

Copyright (c) 2003 Issac Goldstand E<lt>margol@beamartyr.netE<gt> - All rights reserved.

This library is free software. It can be redistributed and/or modified
under the same terms as Perl itself.

=head1 SEE ALSO

L<perl>.

=cut
