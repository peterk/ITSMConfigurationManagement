# --
# Kernel/System/ITSMConfigItem.pm - all config item function
# Copyright (C) 2001-2014 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::ITSMConfigItem;

use strict;
use warnings;

use Kernel::System::EventHandler;
use Kernel::System::GeneralCatalog;
use Kernel::System::ITSMConfigItem::Definition;
use Kernel::System::ITSMConfigItem::History;
use Kernel::System::ITSMConfigItem::Number;
use Kernel::System::ITSMConfigItem::Permission;
use Kernel::System::ITSMConfigItem::Version;
use Kernel::System::ITSMConfigItem::XML;
use Kernel::System::LinkObject;
use Kernel::System::Service;
use Kernel::System::Time;
use Kernel::System::User;
use Kernel::System::XML;
use Kernel::System::VirtualFS;
use Kernel::System::VariableCheck qw(:all);

use vars qw(@ISA);

=head1 NAME

Kernel::System::ITSMConfigItem - config item lib

=head1 SYNOPSIS

All config item functions.

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object

    use Kernel::Config;
    use Kernel::System::Encode;
    use Kernel::System::Log;
    use Kernel::System::DB;
    use Kernel::System::Main;
    use Kernel::System::ITSMConfigItem;

    my $ConfigObject = Kernel::Config->new();
    my $EncodeObject = Kernel::System::Encode->new(
        ConfigObject => $ConfigObject,
    );
    my $LogObject = Kernel::System::Log->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
    );
    my $MainObject = Kernel::System::Main->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
    );
    my $DBObject = Kernel::System::DB->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        MainObject   => $MainObject,
    );
    my $ConfigItemObject = Kernel::System::ITSMConfigItem->new(
        ConfigObject => $ConfigObject,
        EncodeObject => $EncodeObject,
        LogObject    => $LogObject,
        DBObject     => $DBObject,
        MainObject   => $MainObject,
    );

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # check needed objects
    for my $Object (qw(DBObject ConfigObject EncodeObject LogObject MainObject)) {
        $Self->{$Object} = $Param{$Object} || die "Got no $Object!";
    }

    # create additional objects
    $Self->{TimeObject}           = Kernel::System::Time->new( %{$Self} );
    $Self->{GeneralCatalogObject} = Kernel::System::GeneralCatalog->new( %{$Self} );
    $Self->{LinkObject}           = Kernel::System::LinkObject->new( %{$Self} );
    $Self->{UserObject}           = Kernel::System::User->new( %{$Self} );
    $Self->{ServiceObject}        = Kernel::System::Service->new( %{$Self} );
    $Self->{XMLObject}            = Kernel::System::XML->new( %{$Self} );
    $Self->{VirtualFSObject}      = Kernel::System::VirtualFS->new( %{$Self} );

    @ISA = (
        'Kernel::System::ITSMConfigItem::Definition',
        'Kernel::System::ITSMConfigItem::History',
        'Kernel::System::ITSMConfigItem::Number',
        'Kernel::System::ITSMConfigItem::Permission',
        'Kernel::System::ITSMConfigItem::Version',
        'Kernel::System::ITSMConfigItem::XML',
        'Kernel::System::EventHandler',
    );

    # init of event handler
    $Self->EventHandlerInit(
        Config     => 'ITSMConfigItem::EventModulePost',
        BaseObject => 'ConfigItemObject',
        Objects    => {
            %{$Self},
        },
    );

    return $Self;
}

=item ConfigItemCount()

count all records of a config item class

    my $Count = $ConfigItemObject->ConfigItemCount(
        ClassID => 123,
    );

=cut

sub ConfigItemCount {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ClassID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ClassID!',
        );
        return;
    }

    # get state list
    my $StateList = $Self->{GeneralCatalogObject}->ItemList(
        Class       => 'ITSM::ConfigItem::DeploymentState',
        Preferences => {
            Functionality => [ 'preproductive', 'productive' ],
        },
    );

    return 0 if !%{$StateList};

    # create state string
    my $DeplStateString = join q{, }, keys %{$StateList};

    # ask database
    $Self->{DBObject}->Prepare(
        SQL => "SELECT COUNT(id) FROM configitem WHERE class_id = ? AND "
            . "cur_depl_state_id IN ( $DeplStateString )",
        Bind  => [ \$Param{ClassID} ],
        Limit => 1,
    );

    # fetch the result
    my $Count = 0;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $Count = $Row[0];
    }

    return $Count;
}

=item ConfigItemResultList()

return a config item list as array hash reference

    my $ConfigItemListRef = $ConfigItemObject->ConfigItemResultList(
        ClassID => 123,
        Start   => 100,
        Limit   => 50,
    );

=cut

sub ConfigItemResultList {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ClassID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ClassID!',
        );
        return;
    }

    # get state list
    my $StateList = $Self->{GeneralCatalogObject}->ItemList(
        Class       => 'ITSM::ConfigItem::DeploymentState',
        Preferences => {
            Functionality => [ 'preproductive', 'productive' ],
        },
    );

    # create state string
    my $DeplStateString = join q{, }, keys %{$StateList};

    # ask database
    $Self->{DBObject}->Prepare(
        SQL => "SELECT id FROM configitem "
            . "WHERE class_id = ? AND cur_depl_state_id IN ( $DeplStateString ) "
            . "ORDER BY change_time DESC",
        Bind  => [ \$Param{ClassID} ],
        Start => $Param{Start},
        Limit => $Param{Limit},
    );

    # fetch the result
    my @ConfigItemIDList;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push @ConfigItemIDList, $Row[0];
    }

    # get last versions data
    my @ConfigItemList;
    for my $ConfigItemID (@ConfigItemIDList) {

        # get version data
        my $LastVersion = $Self->VersionGet(
            ConfigItemID => $ConfigItemID,
            XMLDataGet   => 0,
        );

        push @ConfigItemList, $LastVersion;
    }

    return \@ConfigItemList;
}

=item ConfigItemGet()

return a config item as hash reference

    my $ConfigItem = $ConfigItemObject->ConfigItemGet(
        ConfigItemID => 123,
        Cache        => 0,    # (optional) default 1 (0|1)
    );

A hashref with the following keys is returned:

    $ConfigItem{ConfigItemID}
    $ConfigItem{Number}
    $ConfigItem{ClassID}
    $ConfigItem{Class}
    $ConfigItem{LastVersionID}
    $ConfigItem{CurDeplStateID}
    $ConfigItem{CurDeplState}
    $ConfigItem{CurDeplStateType}
    $ConfigItem{CurInciStateID}
    $ConfigItem{CurInciState}
    $ConfigItem{CurInciStateType}
    $ConfigItem{CreateTime}
    $ConfigItem{CreateBy}
    $ConfigItem{ChangeTime}
    $ConfigItem{ChangeBy}

=cut

sub ConfigItemGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ConfigItemID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ConfigItemID!',
        );
        return;
    }

    # enable cache per default
    if ( !defined $Param{Cache} ) {
        $Param{Cache} = 1;
    }

    # check if result is already cached
    return $Self->{Cache}->{ConfigItemGet}->{ $Param{ConfigItemID} }
        if $Param{Cache} && $Self->{Cache}->{ConfigItemGet}->{ $Param{ConfigItemID} };

    # ask database
    $Self->{DBObject}->Prepare(
        SQL => 'SELECT id, configitem_number, class_id, last_version_id, '
            . 'cur_depl_state_id, cur_inci_state_id, '
            . 'create_time, create_by, change_time, change_by '
            . 'FROM configitem WHERE id = ?',
        Bind  => [ \$Param{ConfigItemID} ],
        Limit => 1,
    );

    # fetch the result
    my %ConfigItem;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $ConfigItem{ConfigItemID}   = $Row[0];
        $ConfigItem{Number}         = $Row[1];
        $ConfigItem{ClassID}        = $Row[2];
        $ConfigItem{LastVersionID}  = $Row[3];
        $ConfigItem{CurDeplStateID} = $Row[4];
        $ConfigItem{CurInciStateID} = $Row[5];
        $ConfigItem{CreateTime}     = $Row[6];
        $ConfigItem{CreateBy}       = $Row[7];
        $ConfigItem{ChangeTime}     = $Row[8];
        $ConfigItem{ChangeBy}       = $Row[9];
    }

    # check config item
    if ( !$ConfigItem{ConfigItemID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "No such ConfigItemID ($Param{ConfigItemID})!",
        );
        return;
    }

    # get class list
    my $ClassList = $Self->{GeneralCatalogObject}->ItemList(
        Class => 'ITSM::ConfigItem::Class',
    );

    $ConfigItem{Class} = $ClassList->{ $ConfigItem{ClassID} };

    return \%ConfigItem if !$ConfigItem{CurDeplStateID} || !$ConfigItem{CurInciStateID};

    # get deployment state functionality
    my $DeplState = $Self->{GeneralCatalogObject}->ItemGet(
        ItemID => $ConfigItem{CurDeplStateID},
    );

    $ConfigItem{CurDeplState}     = $DeplState->{Name};
    $ConfigItem{CurDeplStateType} = $DeplState->{Functionality};

    # get incident state functionality
    my $InciState = $Self->{GeneralCatalogObject}->ItemGet(
        ItemID => $ConfigItem{CurInciStateID},
    );

    $ConfigItem{CurInciState}     = $InciState->{Name};
    $ConfigItem{CurInciStateType} = $InciState->{Functionality};

    # cache the result
    $Self->{Cache}->{ConfigItemGet}->{ $Param{ConfigItemID} } = \%ConfigItem;

    return \%ConfigItem;
}

=item ConfigItemAdd()

add a new config item

    my $ConfigItemID = $ConfigItemObject->ConfigItemAdd(
        Number  => '111',  # (optional)
        ClassID => 123,
        UserID  => 1,
    );

=cut

sub ConfigItemAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(ClassID UserID)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # get class list
    my $ClassList = $Self->{GeneralCatalogObject}->ItemList(
        Class => 'ITSM::ConfigItem::Class',
    );

    return if !$ClassList;
    return if ref $ClassList ne 'HASH';

    # check the class id
    if ( !$ClassList->{ $Param{ClassID} } ) {

        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'No valid class id given!',
        );
        return;
    }

    # create config item number
    if ( $Param{Number} ) {

        # find existing config item number
        my $Exists = $Self->ConfigItemNumberLookup(
            ConfigItemNumber => $Param{Number},
        );

        if ($Exists) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => 'Config item number already exists!',
            );
            return;
        }
    }
    else {

        # create config item number
        $Param{Number} = $Self->ConfigItemNumberCreate(
            Type    => $Self->{ConfigObject}->Get('ITSMConfigItem::NumberGenerator'),
            ClassID => $Param{ClassID},
        );
    }

    # insert new config item
    my $Success = $Self->{DBObject}->Do(
        SQL => 'INSERT INTO configitem '
            . '(configitem_number, class_id, create_time, create_by, change_time, change_by) '
            . 'VALUES (?, ?, current_timestamp, ?, current_timestamp, ?)',
        Bind => [ \$Param{Number}, \$Param{ClassID}, \$Param{UserID}, \$Param{UserID} ],
    );

    return if !$Success;

    # find id of new item
    $Self->{DBObject}->Prepare(
        SQL => 'SELECT id FROM configitem WHERE '
            . 'configitem_number = ? AND class_id = ? ORDER BY id DESC',
        Bind => [ \$Param{Number}, \$Param{ClassID} ],
        Limit => 1,
    );

    # fetch the result
    my $ConfigItemID;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $ConfigItemID = $Row[0];
    }

    # trigger ConfigItemCreate
    $Self->EventHandler(
        Event => 'ConfigItemCreate',
        Data  => {
            ConfigItemID => $ConfigItemID,
            Comment      => $ConfigItemID . '%%' . $Param{Number},
        },
        UserID => $Param{UserID},
    );

    return $ConfigItemID;
}

=item ConfigItemDelete()

delete an existing config item

    my $True = $ConfigItemObject->ConfigItemDelete(
        ConfigItemID => 123,
        UserID       => 1,
    );

=cut

sub ConfigItemDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(ConfigItemID UserID)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # delete all links to this config item first, before deleting the versions
    return if !$Self->{LinkObject}->LinkDeleteAll(
        Object => 'ITSMConfigItem',
        Key    => $Param{ConfigItemID},
        UserID => $Param{UserID},
    );

    # delete existing versions
    $Self->VersionDelete(
        ConfigItemID => $Param{ConfigItemID},
        UserID       => $Param{UserID},
    );

    # get a list of all attachments
    my @ExistingAttachments = $Self->ConfigItemAttachmentList(
        ConfigItemID => $Param{ConfigItemID},
    );

    # delete all attachments of this config item
    FILENAME:
    for my $Filename (@ExistingAttachments) {

        # delete the attachment
        my $DeletionSuccess = $Self->ConfigItemAttachmentDelete(
            ConfigItemID => $Param{ConfigItemID},
            Filename     => $Filename,
            UserID       => $Param{UserID},
        );

        if ( !$DeletionSuccess ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Unknown problem when deleting attachment $Filename of ConfigItem "
                    . "$Param{ConfigItemID}. Please check the VirtualFS backend for stale "
                    . "files!",
            );
        }
    }

    # trigger ConfigItemDelete event
    # this must be done before deleting the config item from the database,
    # because of a foreign key constraint in the configitem_history table
    $Self->EventHandler(
        Event => 'ConfigItemDelete',
        Data  => {
            ConfigItemID => $Param{ConfigItemID},
            Comment      => $Param{ConfigItemID},
        },
        UserID => $Param{UserID},
    );

    # delete config item
    my $Success = $Self->{DBObject}->Do(
        SQL  => 'DELETE FROM configitem WHERE id = ?',
        Bind => [ \$Param{ConfigItemID} ],
    );

    return $Success;
}

=item ConfigItemAttachmentAdd()

adds an attachment to a config item

    my $Success = $ConfigItemObject->ConfigItemAttachmentAdd(
        ConfigItemID    => 1,
        Filename        => 'filename',
        Content         => 'content',
        ContentType     => 'text/plain',
        UserID          => 1,
    );

=cut

sub ConfigItemAttachmentAdd {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(ConfigItemID Filename Content ContentType UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );

            return;
        }
    }

    # write to virtual fs
    my $Success = $Self->{VirtualFSObject}->Write(
        Filename    => "ConfigItem/$Param{ConfigItemID}/$Param{Filename}",
        Mode        => 'binary',
        Content     => \$Param{Content},
        Preferences => {
            ContentID    => $Param{ContentID},
            ContentType  => $Param{ContentType},
            ConfigItemID => $Param{ConfigItemID},
            UserID       => $Param{UserID},
        },
    );

    # check for error
    if ($Success) {

        # trigger AttachmentAdd-Event
        $Self->EventHandler(
            Event => 'AttachmentAddPost',
            Data  => {
                %Param,
                ConfigItemID => $Param{ConfigItemID},
                Comment      => $Param{Filename},
                HistoryType  => 'AttachmentAdd',
            },
            UserID => $Param{UserID},
        );
    }
    else {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Cannot add attachment for config item $Param{ConfigItemID}",
        );

        return;
    }

    return 1;
}

=item ConfigItemAttachmentDelete()

Delete the given file from the virtual filesystem.

    my $Success = $ConfigItemObject->ConfigItemAttachmentDelete(
        ConfigItemID => 123,               # used in event handling, e.g. for logging the history
        Filename     => 'Projectplan.pdf', # identifies the attachment (together with the ConfigItemID)
        UserID       => 1,
    );

=cut

sub ConfigItemAttachmentDelete {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(ConfigItemID Filename UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );

            return;
        }
    }

    # add prefix
    my $Filename = 'ConfigItem/' . $Param{ConfigItemID} . '/' . $Param{Filename};

    # delete file
    my $Success = $Self->{VirtualFSObject}->Delete(
        Filename => $Filename,
    );

    # check for error
    if ($Success) {

        # trigger AttachmentDeletePost-Event
        $Self->EventHandler(
            Event => 'AttachmentDeletePost',
            Data  => {
                %Param,
                ConfigItemID => $Param{ConfigItemID},
                Comment      => $Param{Filename},
                HistoryType  => 'AttachmentDelete',
            },
            UserID => $Param{UserID},
        );
    }
    else {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Cannot delete attachment $Filename!",
        );

        return;
    }

    return $Success;
}

=item ConfigItemAttachmentGet()

This method returns information about one specific attachment.

    my $Attachment = $ConfigItemObject->ConfigItemAttachmentGet(
        ConfigItemID => 4,
        Filename     => 'test.txt',
    );

returns

    {
        Preferences => {
            AllPreferences => 'test',
        },
        Filename    => 'test.txt',
        Content     => 'content',
        ContentType => 'text/plain',
        Filesize    => '123 KBytes',
        Type        => 'attachment',
    }

=cut

sub ConfigItemAttachmentGet {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Argument (qw(ConfigItemID Filename)) {
        if ( !$Param{$Argument} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Argument!",
            );
            return;
        }
    }

    # add prefix
    my $Filename = 'ConfigItem/' . $Param{ConfigItemID} . '/' . $Param{Filename};

    # find all attachments of this config item
    my @Attachments = $Self->{VirtualFSObject}->Find(
        Filename    => $Filename,
        Preferences => {
            ConfigItemID => $Param{ConfigItemID},
        },
    );

    # return error if file does not exist
    if ( !@Attachments ) {
        $Self->{LogObject}->Log(
            Message  => "No such attachment ($Filename)!",
            Priority => 'error',
        );
        return;
    }

    # get data for attachment
    my %AttachmentData = $Self->{VirtualFSObject}->Read(
        Filename => $Filename,
        Mode     => 'binary',
    );

    my $AttachmentInfo = {
        %AttachmentData,
        Filename    => $Param{Filename},
        Content     => ${ $AttachmentData{Content} },
        ContentType => $AttachmentData{Preferences}->{ContentType},
        Type        => 'attachment',
        Filesize    => $AttachmentData{Preferences}->{Filesize},
    };

    return $AttachmentInfo;
}

=item ConfigItemAttachmentList()

Returns an array with all attachments of the given config item.

    my @Attachments = $ConfigItemObject->ConfigItemAttachmentList(
        ConfigItemID => 123,
    );

returns

    @Attachments = (
        'filename.txt',
        'other_file.pdf',
    );

=cut

sub ConfigItemAttachmentList {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ConfigItemID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ConfigItemID!',
        );

        return;
    }

    # find all attachments of this config item
    my @Attachments = $Self->{VirtualFSObject}->Find(
        Preferences => {
            ConfigItemID => $Param{ConfigItemID},
        },
    );

    for my $Filename (@Attachments) {

        # remove extra information from filename
        $Filename =~ s{ \A ConfigItem / \d+ / }{}xms;
    }

    return @Attachments;
}

=item ConfigItemAttachmentExists()

Checks if a file with a given filename exists.

    my $Exists = $ConfigItemObject->ConfigItemAttachmentExists(
        Filename => 'test.txt',
        ConfigItemID => 123,
        UserID   => 1,
    );

=cut

sub ConfigItemAttachmentExists {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(Filename ConfigItemID UserID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );

            return;
        }
    }

    return if !$Self->{VirtualFSObject}->Find(
        Filename => 'ConfigItem/' . $Param{ConfigItemID} . '/' . $Param{Filename},
    );

    return 1;
}

=item ConfigItemSearchExtended()

return a config item list as an array reference

    my $ConfigItemIDs = $ConfigItemObject->ConfigItemSearchExtended(
        Number       => 'The ConfigItem Number',  # (optional)
        Name         => 'The Name',               # (optional)
        ClassIDs     => [9, 8, 7, 6],             # (optional)
        DeplStateIDs => [1, 2, 3, 4],             # (optional)
        InciStateIDs => [1, 2, 3, 4],             # (optional)

        # config items with created time after ...
        ConfigItemCreateTimeNewerDate => '2006-01-09 00:00:01',  # (optional)
        # config items with created time before then ....
        ConfigItemCreateTimeOlderDate => '2006-01-19 23:59:59',  # (optional)

        # config items with changed time after ...
        ConfigItemChangeTimeNewerDate => '2006-01-09 00:00:01',  # (optional)
        # config items with changed time before then ....
        ConfigItemChangeTimeOlderDate => '2006-01-19 23:59:59',  # (optional)

        What => [
            # each array element is a and condition
            {
                # or condition in hash
                "[%]{'ElementA'}[%]{'ElementB'}[%]{'Content'}" => '%contentA%',
                "[%]{'ElementA'}[%]{'ElementC'}[%]{'Content'}" => '%contentA%',
            },
            {
                "[%]{'ElementA'}[%]{'ElementB'}[%]{'Content'}" => '%contentB%',
                "[%]{'ElementA'}[%]{'ElementC'}[%]{'Content'}" => '%contentB%',
            },
            {
                # use array reference if different content with same key was searched
                "[%]{'ElementA'}[%]{'ElementB'}[%]{'Content'}" => ['%contentC%', '%contentD%', '%contentE%'],
                "[%]{'ElementA'}[%]{'ElementC'}[%]{'Content'}" => ['%contentC%', '%contentD%', '%contentE%'],
            },
        ],

        PreviousVersionSearch => 1,  # (optional) default 0 (0|1)

        OrderBy => [ 'ConfigItemID', 'Number' ],                  # (optional)
        # default: [ 'ConfigItemID' ]
        # (ConfigItemID, Number, ClassID, DeplStateID, InciStateID,
        # CreateTime, CreateBy, ChangeTime, ChangeBy)

        # Additional information for OrderBy:
        # The OrderByDirection can be specified for each OrderBy attribute.
        # The pairing is made by the array indices.

        OrderByDirection => [ 'Down', 'Up' ],                    # (optional)
        # default: [ 'Down' ]
        # (Down | Up)

        Limit          => 122,  # (optional)
        UsingWildcards => 0,    # (optional) default 1
    );

=cut

sub ConfigItemSearchExtended {
    my ( $Self, %Param ) = @_;

    # set limit
    my $Limit = $Param{Limit};
    $Param{Limit} = undef;

    # config item search is required if one of these params is given
    my @ConfigItemSearchParams = (
        'ConfigItemCreateTimeNewerDate',
        'ConfigItemCreateTimeOlderDate',
        'ConfigItemChangeTimeNewerDate',
        'ConfigItemChangeTimeOlderDate',
    );

    # check, if config item search is required
    my %RequiredSearch;
    CONFIGITEMPARAM:
    for my $ConfigItemParam (@ConfigItemSearchParams) {
        next CONFIGITEMPARAM if !$Param{$ConfigItemParam};

        $RequiredSearch{ConfigItem} = 1;
        last CONFIGITEMPARAM;
    }

    # special handling for config item number
    # number 0 is allowed but not the empty string
    if ( defined $Param{Number} && $Param{Number} ne '' ) {
        $RequiredSearch{ConfigItem} = 1;
    }

    # version search is required if Name, What or PreviousVersionSearch is given
    if (
        ( defined $Param{Name} && $Param{Name} ne '' )
        || ( defined $Param{What} && $Param{What} ne '' )
        || $Param{PreviousVersionSearch}
        )
    {
        $RequiredSearch{Version} = 1;
    }

    # version search is also required if sorting by name (fix for bug #7072)
    ORDERBY:
    for my $OrderBy ( @{ $Param{OrderBy} } ) {
        if ( $OrderBy eq 'Name' ) {
            $RequiredSearch{Version} = 1;
            last ORDERBY;
        }
    }

    # xml version search is required if What is given
    if ( defined $Param{What} && $Param{What} ne '' ) {
        $RequiredSearch{XMLVersion} = 1;
    }

    # use config item search as fallback
    if ( !%RequiredSearch ) {
        $RequiredSearch{ConfigItem} = 1;
    }

    # start config item search
    my %ConfigItemLists;
    if ( $RequiredSearch{ConfigItem} ) {

        # search config items
        $ConfigItemLists{ConfigItem} = $Self->ConfigItemSearch(%Param);

        return if !$ConfigItemLists{ConfigItem};
        return if ref $ConfigItemLists{ConfigItem} ne 'ARRAY';
        return [] if !@{ $ConfigItemLists{ConfigItem} };
    }

    # start version search
    if ( $RequiredSearch{Version} ) {

        # search versions
        $ConfigItemLists{Version} = $Self->VersionSearch(%Param);

        return if !$ConfigItemLists{Version};
        return if ref $ConfigItemLists{Version} ne 'ARRAY';
        return [] if !@{ $ConfigItemLists{Version} };
    }

    # start xml version search
    if ( $RequiredSearch{XMLVersion} ) {

        # search xml versions
        my $XMLVersionList = $Self->_XMLVersionSearch(%Param);

        return if !$XMLVersionList;
        return if ref $XMLVersionList ne 'HASH';
        return [] if !%{$XMLVersionList};

        # get config item ids
        my %ConfigItemListTmp;
        for my $VersionID ( sort keys %{$XMLVersionList} ) {
            my $ConfigItemID = $Self->VersionConfigItemIDGet(
                VersionID => $VersionID,
            );
            $ConfigItemListTmp{$ConfigItemID} = 1;
        }

        # add ids to config item list
        $ConfigItemLists{XMLVersion} = \%ConfigItemListTmp;
    }

    # create the result list
    my @ResultList;
    if ( $RequiredSearch{ConfigItem} && $RequiredSearch{Version} ) {

        my %VersionTempList;
        for my $ConfigItemID ( @{ $ConfigItemLists{Version} } ) {
            $VersionTempList{$ConfigItemID} = 1;
        }

        CONFIGITEMID:
        for my $ConfigItemID ( @{ $ConfigItemLists{ConfigItem} } ) {

            next CONFIGITEMID if !$VersionTempList{$ConfigItemID};

            push @ResultList, $ConfigItemID;
        }
    }
    elsif ( $RequiredSearch{ConfigItem} ) {
        @ResultList = @{ $ConfigItemLists{ConfigItem} };
    }
    elsif ( $RequiredSearch{Version} ) {
        @ResultList = @{ $ConfigItemLists{Version} };
    }

    # consider the XML result
    if ( $RequiredSearch{XMLVersion} ) {
        @ResultList = grep { $ConfigItemLists{XMLVersion}->{$_} } @ResultList;
    }

    # consider limit
    if ( $Limit && $Limit < scalar @ResultList ) {

        # extract the limited ids
        $Limit--;
        @ResultList = @ResultList[ 0 .. $Limit ];
    }

    return \@ResultList;
}

=item ConfigItemSearch()

return a config item list as an array reference

    my $ConfigItemIDs = $ConfigItemObject->ConfigItemSearch(
        Number       => 'The ConfigItem Number',  # (optional)
        ClassIDs     => [9, 8, 7, 6],             # (optional)
        DeplStateIDs => [1, 2, 3, 4],             # (optional)
        InciStateIDs => [1, 2, 3, 4],             # (optional)
        CreateBy     => [1, 2, 3],                # (optional)
        ChangeBy     => [3, 2, 1],                # (optional)

        # config items with created time after ...
        ConfigItemCreateTimeNewerDate => '2006-01-09 00:00:01',  # (optional)
        # config items with created time before then ....
        ConfigItemCreateTimeOlderDate => '2006-01-19 23:59:59',  # (optional)

        # config items with changed time after ...
        ConfigItemChangeTimeNewerDate => '2006-01-09 00:00:01',  # (optional)
        # config items with changed time before then ....
        ConfigItemChangeTimeOlderDate => '2006-01-19 23:59:59',  # (optional)

        OrderBy => [ 'ConfigItemID', 'Number' ],                  # (optional)
        # default: [ 'ConfigItemID' ]
        # (ConfigItemID, Number, ClassID, DeplStateID, InciStateID,
        # CreateTime, CreateBy, ChangeTime, ChangeBy)

        # Additional information for OrderBy:
        # The OrderByDirection can be specified for each OrderBy attribute.
        # The pairing is made by the array indices.

        OrderByDirection => [ 'Down', 'Up' ],                    # (optional)
        # default: [ 'Down' ]
        # (Down | Up)

        Limit          => 122,  # (optional)
        UsingWildcards => 0,    # (optional) default 1
    );

=cut

sub ConfigItemSearch {
    my ( $Self, %Param ) = @_;

    # verify that all passed array parameters contain an arrayref
    ARGUMENT:
    for my $Argument (
        qw(
        OrderBy
        OrderByDirection
        )
        )
    {
        if ( !defined $Param{$Argument} ) {
            $Param{$Argument} ||= [];

            next ARGUMENT;
        }

        if ( ref $Param{$Argument} ne 'ARRAY' ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "$Argument must be an array reference!",
            );
            return;
        }
    }

    # define order table
    my %OrderByTable = (
        ConfigItemID => 'id',
        Number       => 'configitem_number',
        ClassID      => 'class_id',
        DeplStateID  => 'cur_depl_state_id',
        InciStateID  => 'cur_inci_state_id',
        CreateTime   => 'create_time',
        CreateBy     => 'create_by',
        ChangeTime   => 'change_time',
        ChangeBy     => 'change_by',
    );

    # check if OrderBy contains only unique valid values
    my %OrderBySeen;
    ORDERBY:
    for my $OrderBy ( @{ $Param{OrderBy} } ) {

        next ORDERBY if $OrderBy eq 'Name';

        if ( !$OrderBy || !$OrderByTable{$OrderBy} || $OrderBySeen{$OrderBy} ) {

            # found an error
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "OrderBy contains invalid value '$OrderBy' "
                    . 'or the value is used more than once!',
            );
            return;
        }

        # remember the value to check if it appears more than once
        $OrderBySeen{$OrderBy} = 1;
    }

    # check if OrderByDirection array contains only 'Up' or 'Down'
    DIRECTION:
    for my $Direction ( @{ $Param{OrderByDirection} } ) {

        # only 'Up' or 'Down' allowed
        next DIRECTION if $Direction eq 'Up';
        next DIRECTION if $Direction eq 'Down';

        # found an error
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "OrderByDirection can only contain 'Up' or 'Down'!",
        );
        return;
    }

    # set default values
    if ( !defined $Param{UsingWildcards} ) {
        $Param{UsingWildcards} = 1;
    }

    # get like escape string needed for some databases (e.g. oracle)
    my $LikeEscapeString = $Self->{DBObject}->GetDatabaseFunction('LikeEscapeString');

    # assemble the ORDER BY clause
    my @SQLOrderBy;
    my $Count = 0;
    ORDERBY:
    for my $OrderBy ( @{ $Param{OrderBy} } ) {

        next ORDERBY if $OrderBy eq 'Name';

        # set the default order direction
        my $Direction = 'DESC';

        # add the given order direction
        if ( $Param{OrderByDirection}->[$Count] ) {
            if ( $Param{OrderByDirection}->[$Count] eq 'Up' ) {
                $Direction = 'ASC';
            }
            elsif ( $Param{OrderByDirection}->[$Count] eq 'Down' ) {
                $Direction = 'DESC';
            }
        }

        # add SQL
        push @SQLOrderBy, "$OrderByTable{$OrderBy} $Direction";

    }
    continue {
        $Count++;
    }

    # if there is a possibility that the ordering is not determined
    # we add an ascending ordering by id
    if ( !grep { $_ eq 'ConfigItemID' } ( @{ $Param{OrderBy} } ) ) {
        push @SQLOrderBy, "$OrderByTable{ConfigItemID} ASC";
    }

    # add number to sql where array
    my @SQLWhere;
    if ( defined $Param{Number} && $Param{Number} ne '' ) {

        # quote
        $Param{Number} = $Self->{DBObject}->Quote( $Param{Number} );

        if ( $Param{UsingWildcards} ) {

            # prepare like string
            $Self->_PrepareLikeString( \$Param{Number} );

            push @SQLWhere,
                "LOWER(configitem_number) LIKE LOWER('$Param{Number}') $LikeEscapeString";
        }
        else {
            push @SQLWhere, "LOWER(configitem_number) = LOWER('$Param{Number}')";
        }
    }

    # set array params
    my %ArrayParams = (
        ClassIDs     => 'class_id',
        DeplStateIDs => 'cur_depl_state_id',
        InciStateIDs => 'cur_inci_state_id',
        CreateBy     => 'create_by',
        ChangeBy     => 'change_by',
    );

    ARRAYPARAM:
    for my $ArrayParam ( sort keys %ArrayParams ) {

        next ARRAYPARAM if !$Param{$ArrayParam};

        if ( ref $Param{$ArrayParam} ne 'ARRAY' ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "$ArrayParam must be an array reference!",
            );
            return;
        }

        next ARRAYPARAM if !@{ $Param{$ArrayParam} };

        # quote as integer
        for my $OneParam ( @{ $Param{$ArrayParam} } ) {
            $OneParam = $Self->{DBObject}->Quote( $OneParam, 'Integer' );
        }

        # create string
        my $InString = join q{, }, @{ $Param{$ArrayParam} };

        next ARRAYPARAM if !$InString;

        push @SQLWhere, "$ArrayParams{ $ArrayParam } IN ($InString)";
    }

    # set time params
    my %TimeParams = (
        ConfigItemCreateTimeNewerDate => 'create_time >=',
        ConfigItemCreateTimeOlderDate => 'create_time <=',
        ConfigItemChangeTimeNewerDate => 'change_time >=',
        ConfigItemChangeTimeOlderDate => 'change_time <=',
    );

    TIMEPARAM:
    for my $TimeParam ( sort keys %TimeParams ) {

        next TIMEPARAM if !$Param{$TimeParam};

        if ( $Param{$TimeParam} !~ m{ \A \d\d\d\d-\d\d-\d\d \s \d\d:\d\d:\d\d \z }xms ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Invalid date format found!",
            );
            return;
        }

        # quote
        $Param{$TimeParam} = $Self->{DBObject}->Quote( $Param{$TimeParam} );

        push @SQLWhere, "$TimeParams{ $TimeParam } '$Param{ $TimeParam }'";
    }

    # create where string
    my $WhereString = @SQLWhere ? ' WHERE ' . join q{ AND }, @SQLWhere : '';

    # set limit
    if ( $Param{Limit} ) {
        $Param{Limit} = $Self->{DBObject}->Quote( $Param{Limit}, 'Integer' );
    }

    my $SQL = "SELECT id FROM configitem $WhereString ";

    # add the ORDER BY clause
    if (@SQLOrderBy) {
        $SQL .= 'ORDER BY ';
        $SQL .= join ', ', @SQLOrderBy;
        $SQL .= ' ';
    }

    # ask database
    $Self->{DBObject}->Prepare(
        SQL   => $SQL,
        Limit => $Param{Limit},
    );

    # fetch the result
    my @ConfigItemList;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push @ConfigItemList, $Row[0];
    }

    return \@ConfigItemList;
}

=item ConfigItemLookup()

This method does a lookup for a configitem. If a configitem id is given,
it returns the number of the configitem. If a configitem number is given,
the appropriate id is returned.

    my $Number = $ConfigItemObject->ConfigItemLookup(
        ConfigItemID => 1234,
    );

    my $ID = $ConfigItemObject->ConfigItemLookup(
        ConfigItemNumber => 1000001,
    );

=cut

sub ConfigItemLookup {
    my ( $Self, %Param ) = @_;

    my ($Key) = grep { $Param{$_} } qw(ConfigItemID ConfigItemNumber);

    # check for needed stuff
    if ( !$Key ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ConfigItemID or ConfigItemNumber!',
        );
        return;
    }

    # if result is cached return that result
    return $Self->{Cache}->{ConfigItemLookup}->{$Key}->{ $Param{$Key} }
        if $Self->{Cache}->{ConfigItemLookup}->{$Key}->{ $Param{$Key} };

    # set the appropriate SQL statement
    my $SQL = 'SELECT configitem_number FROM configitem WHERE id = ?';

    if ( $Key eq 'ConfigItemNumber' ) {
        $SQL = 'SELECT id FROM configitem WHERE configitem_number = ?';
    }

    # fetch the requested value
    return if !$Self->{DBObject}->Prepare(
        SQL   => $SQL,
        Bind  => [ \$Param{$Key} ],
        Limit => 1,
    );

    my $Value;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $Value = $Row[0];
    }

    $Self->{Cache}->{ConfigItemLookup}->{$Key}->{ $Param{$Key} } = $Value;

    return $Value;
}

=item UniqueNameCheck()

This method checks all already existing config items, whether the given name does already exist
within the same config item class or amongst all classes, depending on the SysConfig value of
UniqueCIName::UniquenessCheckScope (Class or Global).

This method requires 3 parameters: ConfigItemID, Name and Class
"ConfigItemID"  is the ID of the ConfigItem, which is to be checked for uniqueness
"Name"          is the config item name to be checked for uniqueness
"ClassID"       is the ID of the config item's class

All parameters are mandatory.

my $DuplicateNames = $ConfigItemObject->UniqueNameCheck(
    ConfigItemID => '73'
    Name         => 'PC#005',
    ClassID      => '32',
);

The given name is not unique
my $NameDuplicates = [ 5, 35, 48, ];    # IDs of ConfigItems with the same name

The given name is unique
my $NameDuplicates = [];

=cut

sub UniqueNameCheck {
    my ( $Self, %Param ) = @_;

    # check for needed stuff
    for my $Needed (qw(ConfigItemID Name ClassID)) {
        if ( !$Param{$Needed} ) {
            $Self->{LogObject}->Log(
                Priority => 'error',
                Message  => "Missing parameter $Needed!",
            );
            return;
        }
    }

    # check ConfigItemID param for valid format
    if (
        !IsInteger( $Param{ConfigItemID} )
        && ( IsStringWithData( $Param{ConfigItemID} ) && $Param{ConfigItemID} ne 'NEW' )
        )
    {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The ConfigItemID parameter needs to be an integer or 'NEW'",
        );
        return;
    }

    # check Name param for valid format
    if ( !IsStringWithData( $Param{Name} ) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The Name parameter needs to be a string!",
        );
        return;
    }

    # check ClassID param for valid format
    if ( !IsInteger( $Param{ClassID} ) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The ClassID parameter needs to be an integer",
        );
        return;
    }

    # get class list
    my $ClassList = $Self->{GeneralCatalogObject}->ItemList(
        Class => 'ITSM::ConfigItem::Class',
    );

    # check class list for validity
    if ( !IsHashRefWithData($ClassList) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Unable to retrieve a valid class list!",
        );
        return;
    }

    # get the class name from the class list
    my $Class = $ClassList->{ $Param{ClassID} };

    # check class for validity
    if ( !IsStringWithData($Class) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "Unable to determine a config item class using the given ClassID!",
        );
        return;
    }
    elsif ( $Self->{ConfigObject}->{Debug} > 0 ) {
        $Self->{LogObject}->Log(
            Priority => 'debug',
            Message  => "Resolved ClassID $Param{ClassID} to class $Class",
        );
    }

    # get the uniqueness scope from SysConfig
    my $Scope = $Self->{ConfigObject}->Get('UniqueCIName::UniquenessCheckScope');

    # check scope for validity
    if ( !IsStringWithData($Scope) ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "The configuration of UniqueCIName::UniquenessCheckScope is invalid!",
        );
        return;
    }

    if ( $Scope ne 'global' && $Scope ne 'class' ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => "UniqueCIName::UniquenessCheckScope is $Scope, but must be either "
                . "'global' or 'class'!",
        );
        return;
    }

    if ( $Self->{ConfigObject}->{Debug} > 0 ) {
        $Self->{LogObject}->Log(
            Priority => 'debug',
            Message  => "The scope for checking the uniqueness is $Scope",
        );
    }

    my %SearchCriteria;

    # add the config item class to the search criteria if the uniqueness scope is not global
    if ( $Scope ne 'global' ) {
        $SearchCriteria{ClassIDs} = [ $Param{ClassID} ];
    }

    $SearchCriteria{Name} = $Param{Name};

    # search for a config item matching the given name
    my $ConfigItem = $Self->ConfigItemSearchExtended(%SearchCriteria);

    # remove the provided ConfigItemID from the results, otherwise the duplicate check would fail
    # because the ConfigItem itself is found as duplicate
    my @Duplicates = map {$_} grep { $_ ne $Param{ConfigItemID} } @{$ConfigItem};

    # if a config item was found, the given name is not unique
    # if no config item was found, the given name is unique

    # return the result of the config item search for duplicates
    return \@Duplicates;
}

=item CurInciStateRecalc()

recalculates the current incident state of this config item and all linked config items

    my $Success = $ConfigItemObject->CurInciStateRecalc(
        ConfigItemID => 123,
    );

=cut

sub CurInciStateRecalc {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    if ( !$Param{ConfigItemID} ) {
        $Self->{LogObject}->Log(
            Priority => 'error',
            Message  => 'Need ConfigItemID!',
        );
        return;
    }

    # get incident link type from config
    my $LinkType = $Self->{ConfigObject}->Get('ITSM::Core::IncidentLinkType');

    # remember the scanned config items
    my %ScannedConfigItemIDs;

    # find all config items with an incident state
    $Self->_FindInciConfigItems(
        ConfigItemID         => $Param{ConfigItemID},
        LinkType             => $LinkType,
        ScannedConfigItemIDs => \%ScannedConfigItemIDs,
    );

    # investigate all config items with a warning state
    CONFIGITEMID:
    for my $ConfigItemID ( sort keys %ScannedConfigItemIDs ) {

        next CONFIGITEMID if $ScannedConfigItemIDs{$ConfigItemID}->{Type} ne 'incident';

        $Self->_FindWarnConfigItems(
            ConfigItemID         => $ConfigItemID,
            LinkType             => $LinkType,
            ScannedConfigItemIDs => \%ScannedConfigItemIDs,
        );
    }

    # get the incident state list of warnings
    my $WarnStateList = $Self->{GeneralCatalogObject}->ItemList(
        Class       => 'ITSM::Core::IncidentState',
        Preferences => {
            Functionality => 'warning',
        },
    );

    my %ReverseWarnStateList = reverse %{$WarnStateList};
    my @SortedWarnList       = sort keys %ReverseWarnStateList;
    my $WarningStateID
        = $ReverseWarnStateList{Warning} || $ReverseWarnStateList{ $SortedWarnList[0] };

    # to store the relation between services and linked CIs
    my %ServiceCIRelation;

    CONFIGITEMID:
    for my $ConfigItemID ( sort keys %ScannedConfigItemIDs ) {

        # extract incident state type
        my $InciStateType = $ScannedConfigItemIDs{$ConfigItemID}->{Type};

        # find all linked services of this CI
        my %LinkedServiceIDs = $Self->{LinkObject}->LinkKeyListWithData(
            Object1 => 'ITSMConfigItem',
            Key1    => $ConfigItemID,
            Object2 => 'Service',
            State   => 'Valid',
            Type    => $LinkType,
            UserID  => 1,
        );

        SERVICEID:
        for my $ServiceID ( sort keys %LinkedServiceIDs ) {

            # remember the CIs that are linked with this service
            push @{ $ServiceCIRelation{$ServiceID} }, $ConfigItemID;
        }

        next CONFIGITEMID if $InciStateType eq 'incident';

        my $CurInciStateID = $WarningStateID;
        if ( $InciStateType eq 'operational' ) {

            # get last version
            my $LastVersion = $Self->VersionGet(
                ConfigItemID => $ConfigItemID,
                XMLDataGet   => 0,
            );

            $CurInciStateID = $LastVersion->{InciStateID};
        }

        # update current incident state
        $Self->{DBObject}->Do(
            SQL => "UPDATE configitem SET cur_inci_state_id = $CurInciStateID "
                . "WHERE id = $ConfigItemID",
        );
    }

    # set the current incident state type for each service (influenced by linked CIs)
    SERVICEID:
    for my $ServiceID ( sort keys %ServiceCIRelation ) {

        # set default incident state type
        my $CurInciStateTypeFromCIs = 'operational';

        # investigate the current incident state of each config item
        CONFIGITEMID:
        for my $ConfigItemID ( @{ $ServiceCIRelation{$ServiceID} } ) {

            # get config item data
            my $ConfigItemData = $Self->ConfigItemGet(
                ConfigItemID => $ConfigItemID,
                Cache        => 0,
            );

            next CONFIGITEMID if $ConfigItemData->{CurDeplStateType} ne 'productive';
            next CONFIGITEMID if $ConfigItemData->{CurInciStateType} eq 'operational';

            # check if service must be set to 'warning'
            if ( $ConfigItemData->{CurInciStateType} eq 'warning' ) {
                $CurInciStateTypeFromCIs = 'warning';
                next CONFIGITEMID;
            }

            # check if service must be set to 'incident'
            if ( $ConfigItemData->{CurInciStateType} eq 'incident' ) {
                $CurInciStateTypeFromCIs = 'incident';
                last CONFIGITEMID;
            }
        }

        # update the current incident state type from CIs of the service
        $Self->{ServiceObject}->ServicePreferencesSet(
            ServiceID => $ServiceID,
            Key       => 'CurInciStateTypeFromCIs',
            Value     => $CurInciStateTypeFromCIs,
            UserID    => 1,
        );
    }

    return 1;
}

=begin Internal:

=item _FindInciConfigItems()

find all config items with an incident state

    $ConfigItemObject->_FindInciConfigItems(
        ConfigItemID         => $ConfigItemID,
        LinkType             => $LinkType,
        ScannedConfigItemIDs => \%ScannedConfigItemIDs,
    );

=cut

sub _FindInciConfigItems {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    return if !$Param{ConfigItemID};

    # ignore already scanned ids (infinite loop protection)
    return if $Param{ScannedConfigItemIDs}->{ $Param{ConfigItemID} };

    $Param{ScannedConfigItemIDs}->{ $Param{ConfigItemID} }->{Type} = 'operational';

    # find all linked config items (childs)
    my %LinkedConfigItemIDs = $Self->{LinkObject}->LinkKeyList(
        Object1   => 'ITSMConfigItem',
        Key1      => $Param{ConfigItemID},
        Object2   => 'ITSMConfigItem',
        State     => 'Valid',
        Type      => $Param{LinkType},
        Direction => 'Both',
        UserID    => 1,
    );

    # add own config item id to list of linked config items
    my @ConfigItemIDs = ( $Param{ConfigItemID}, keys %LinkedConfigItemIDs );

    CONFIGITEMID:
    for my $ConfigItemID (@ConfigItemIDs) {

        # get config item data
        my $ConfigItem = $Self->ConfigItemGet(
            ConfigItemID => $ConfigItemID,
            Cache        => 0,
        );

        # set incident state
        if ( $ConfigItem->{CurInciStateType} eq 'incident' ) {
            $Param{ScannedConfigItemIDs}->{$ConfigItemID}->{Type} = 'incident';
            next CONFIGITEMID;
        }

        # start recursion
        $Self->_FindInciConfigItems(
            ConfigItemID         => $ConfigItemID,
            LinkType             => $Param{LinkType},
            ScannedConfigItemIDs => $Param{ScannedConfigItemIDs},
        );
    }

    return 1;
}

=item _FindWarnConfigItems()

find all config items with a warning

    $ConfigItemObject->_FindWarnConfigItems(
        ConfigItemID         => $ConfigItemID,
        LinkType             => $LinkType,
        ScannedConfigItemIDs => $ScannedConfigItemIDs,
    );

=cut

sub _FindWarnConfigItems {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    return if !$Param{ConfigItemID};

    # ignore already scanned ids (infinite loop protection)
    return if $Param{ScannedConfigItemIDs}->{ $Param{ConfigItemID} }->{FindWarn};
    $Param{ScannedConfigItemIDs}->{ $Param{ConfigItemID} }->{FindWarn} = 1;

    # find all linked config items (parents)
    my %LinkedConfigItemIDs = $Self->{LinkObject}->LinkKeyList(
        Object1   => 'ITSMConfigItem',
        Key1      => $Param{ConfigItemID},
        Object2   => 'ITSMConfigItem',
        State     => 'Valid',
        Type      => $Param{LinkType},
        Direction => 'Both',
        UserID    => 1,
    );

    CONFIGITEMID:
    for my $ConfigItemID ( sort keys %LinkedConfigItemIDs ) {

        # start recursion
        $Self->_FindWarnConfigItems(
            ConfigItemID         => $ConfigItemID,
            LinkType             => $Param{LinkType},
            ScannedConfigItemIDs => $Param{ScannedConfigItemIDs},
        );

        next CONFIGITEMID
            if $Param{ScannedConfigItemIDs}->{$ConfigItemID}->{Type}
            && $Param{ScannedConfigItemIDs}->{$ConfigItemID}->{Type} eq 'incident';

        # set warning state
        $Param{ScannedConfigItemIDs}->{$ConfigItemID}->{Type} = 'warning';
    }

    return 1;
}

=item _PrepareLikeString()

internal function to prepare like strings

    $ConfigItemObject->_PrepareLikeString( $StringRef );

=cut

sub _PrepareLikeString {
    my ( $Self, $Value ) = @_;

    return if !$Value;
    return if ref $Value ne 'SCALAR';

    # Quote
    ${$Value} = $Self->{DBObject}->Quote( ${$Value}, 'Like' );

    # replace * with %
    ${$Value} =~ s{ \*+ }{%}xmsg;

    return;
}

1;

=end Internal:

=back

=head1 ITSM Config Item events:

ConfigItemCreate, VersionCreate, DeploymentStateUpdate, IncidentStateUpdate,
ConfigItemDelete, LinkAdd, LinkDelete, DefinitionUpdate, NameUpdate, ValueUpdate
DefinitionCreate, VersionDelete

=cut

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (http://otrs.org/).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
