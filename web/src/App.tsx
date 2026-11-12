import { AdminConsole } from '@/admin/AdminConsole';
import { PlacerHud } from '@/placer/PlacerHud';

/**
 * Two surfaces share one page: the placer's strip while a rack is being put down with the gizmo (by
 * a player using a rack item, or by staff from the console), and the staff console. Each listens for
 * its own message from Lua and renders nothing until it arrives, so mounting both costs nothing while
 * the resource is idle.
 *
 * The strip takes no focus of its own: the game keeps the mouse for the gizmo while it is up, and it
 * is drawn under the console should one come up over it.
 */
export default function App() {
  return (
    <>
      <PlacerHud />
      <AdminConsole />
    </>
  );
}
