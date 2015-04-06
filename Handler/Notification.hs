module Handler.Notification where

import Import hiding (delete)

import           Model.Notification
import           Model.Project
import           Model.User
import qualified Data.Foldable as F
import           Data.List (sortBy)
import qualified Data.Text as T
import           Widgets.Time

-- Merge two notification types together.  This should only be used
-- for rendering.
data Notification
    = UNotification UserNotificationId    UserNotification
    | PNotification ProjectNotificationId ProjectNotification

-- The arguments of 'compare' are intentionally swapped, so the newest
-- notifications are listed first.
compareCreatedTs :: Notification -> Notification -> Ordering
compareCreatedTs (UNotification _ un1) (UNotification _ un2)
    = compare (userNotificationCreatedTs un2)
              (userNotificationCreatedTs un1)
compareCreatedTs (UNotification _ un) (PNotification _ pn)
    = compare (projectNotificationCreatedTs pn)
              (userNotificationCreatedTs un)
compareCreatedTs (PNotification _ pn) (UNotification _ un)
    = compare (userNotificationCreatedTs un)
              (projectNotificationCreatedTs pn)
compareCreatedTs (PNotification _ pn1) (PNotification _ pn2)
    = compare (projectNotificationCreatedTs pn2)
              (projectNotificationCreatedTs pn1)

getNotificationsR :: Handler Html
getNotificationsR = do
    user_id <- requireAuthId
    (user_notifs, project_notifs) <- runDB $ do
        userReadNotificationsDB user_id
        user_notifs    <- fetchUserNotificationsDB user_id
        project_notifs <- fetchProjectNotificationsDB user_id
        return (user_notifs, project_notifs)
    let notifs = sortBy compareCreatedTs
               $ ((\(Entity un_id un) -> UNotification un_id un) <$> user_notifs)
              <> ((\(Entity pn_id pn) -> PNotification pn_id pn) <$> project_notifs)
    defaultLayout $ do
        snowdriftTitle "Notifications"
        $(widgetFile "notifications")

whenNotifId :: (PersistEntity r, DBConstraint m)
            => Text -> (Key r -> m ()) -> m ()
whenNotifId value action =
    F.forM_ (readMaybe $ T.unpack value :: Maybe Int) $ \notif_id ->
        action $ key $ toPersistValue notif_id

whenUserNotifId :: DBConstraint m => Text -> (UserNotificationId -> m ()) -> m ()
whenUserNotifId = whenNotifId

whenProjectNotifId :: DBConstraint m => Text -> (ProjectNotificationId -> m ()) -> m ()
whenProjectNotifId = whenNotifId

proxyNotifications :: RedirectUrl App route => Text -> Text
                   -> (UserId -> DB ()) -> (UserId -> DB ())
                   -> (UserNotificationId -> DB ()) -> (UserNotificationId -> DB ())
                   -> (ProjectNotificationId -> DB ()) -> (ProjectNotificationId -> DB ())
                   -> route -> Handler Html
proxyNotifications value1 value2 action_all1 action_all2
                   action_user_notif1 action_user_notif2
                   action_project_notif1 action_project_notif2 route = do
    user_id <- requireAuthId
    req <- getRequest
    let params = reqGetParams req
        names  = fst `map` params
        handleAction :: DB () -> DB () -> DB ()
        handleAction action1 action2 =
            if | value1 `elem` names -> action1
               | value2 `elem` names -> action2
               | otherwise -> return ()
    forM_ params $ \(name, value) ->
        if | name == "all" ->
                 runDB $ handleAction (action_all1 user_id)
                                      (action_all2 user_id)
           | name == "user_notification" ->
                 whenUserNotifId value $ \notif_id -> runDB $
                     handleAction (action_user_notif1 notif_id)
                                  (action_user_notif2 notif_id)
           | name == "project_notification" ->
                 whenProjectNotifId value $ \notif_id -> runDB $
                     handleAction (action_project_notif1 notif_id)
                                  (action_project_notif2 notif_id)
           | otherwise -> return ()
    redirect route

getNotificationsProxyR :: Handler Html
getNotificationsProxyR =
    proxyNotifications "archive" "delete"
        archiveNotificationsDB deleteNotificationsDB
        archiveUserNotificationDB deleteUserNotificationDB
        archiveProjectNotificationDB deleteProjectNotificationDB
        NotificationsR

getArchivedNotificationsR :: Handler Html
getArchivedNotificationsR = do
    user_id <- requireAuthId
    (user_notifs, project_notifs) <- runDB $ (,)
        <$> fetchArchivedUserNotificationsDB user_id
        <*> fetchArchivedProjectNotificationsDB user_id
    let notifs = sortBy compareCreatedTs
               $ ((\(Entity un_id un) -> UNotification un_id un) <$> user_notifs)
              <> ((\(Entity pn_id pn) -> PNotification pn_id pn) <$> project_notifs)
    defaultLayout $ do
        snowdriftTitle "Archived Notifications"
        $(widgetFile "archived_notifications")

getArchivedNotificationsProxyR :: Handler Html
getArchivedNotificationsProxyR =
    proxyNotifications "unarchive" "delete"
        unarchiveNotificationsDB deleteArchivedNotificationsDB
        unarchiveUserNotificationDB deleteUserNotificationDB
        unarchiveProjectNotificationDB deleteProjectNotificationDB
        ArchivedNotificationsR
