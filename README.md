# Codex Switchboard

[English documentation](README.en.md)

Gestor local de cuentas para Codex en macOS. Mantiene una sola instancia visual de la app oficial, consulta identidad y cuota mediante el `app-server` instalado con Codex y conserva un único almacén de conversaciones.

## Qué hace

- Detecta el plan, las ventanas de uso y el agotamiento real con `account/read` y `account/rateLimits/read`.
- Prefiere el mapa moderno `rateLimitsByLimitId.codex` y conserva compatibilidad con el formato anterior `rateLimits`. Nunca presenta un intento fallido como una actualización correcta.
- Muestra ambas ventanas en la lista, recomienda el siguiente destino protegiendo primero la cuota más escasa y permite excluir cuentas concretas de la rotación automática.
- Conserva un registro local breve de cambios y recuperaciones, sin tokens ni contenido de conversaciones.
- Muestra el plan detectado junto al nombre y correo en la lista, la ficha y el menú de la barra superior. Si Codex no entrega ese dato, muestra `Plan no disponible` sin inferirlo por la cuota.
- Incluye `Gestionar plan en Opera` con un directorio de usuario persistente y aislado por cuenta. No comparte cookies, historial ni sesiones con el perfil normal de Opera ni con otras cuentas. Abre ChatGPT directamente, sin extensión, depuración remota ni pestañas intermedias.
- Si el perfil aislado todavía no registra la VPN de Opera como activa, abre primero su configuración y no navega a facturación. Cuando está activa, abre la gestión oficial de ChatGPT y mantiene esa sesión para usos posteriores.
- Si ChatGPT solicita acceso, el usuario puede cerrar Ajustes, iniciar sesión normalmente y entrar en `Perfil → Ajustes → Billing`; Switchboard no fuerza ni reabre el panel.
- Añade cuentas mediante el OAuth oficial, sin pedir contraseñas ni copiar tokens.
- Permite cerrar la sesión de una cuenta sin borrarla. También permite eliminar cuentas inactivas: mueve su carpeta local a la Papelera y conserva las conversaciones compartidas.
- Mantiene cada autenticación bajo `~/Library/Application Support/Codex Switchboard` con permisos `0700` y conserva historial, proyectos y configuración en `~/.codex`.
- Abre la app oficial con un solo perfil cada vez. Si hay otra instancia, solicita su cierre normal antes de abrir la siguiente.
- Antes de bloquear un cambio manual, comprueba actividad operativa: una respuesta `final_answer` deja de bloquear inmediatamente aunque SQLite conserve temporalmente `inProgress`; el resto requiere una herramienta realmente en curso, un arranque reciente o actividad persistida en los últimos 45 segundos.
- Cuando la cuenta activa ya tiene un `usageLimitExceeded` confirmado, los registros de modelo o razonamiento `inProgress` se consideran interrumpidos por el límite y no bloquean. Solo se protege una herramienta local cuyo propio estado siga realmente `inProgress`.
- El aviso enumera las tareas detectadas y permite `Forzar cambio`. Forzar cierra Codex y puede interrumpir trabajo no guardado, por lo que siempre requiere una confirmación explícita del usuario.
- Puede seleccionar automáticamente otra cuenta disponible al agotarse la activa.
- La versión 0.3 incorpora un bridge externo seleccionado mediante `CODEX_CLI_PATH`. La app oficial, su `app.asar`, su firma y el binario de Codex permanecen intactos: el bridge retransmite su protocolo `stdio` y añade un canal de control local con permisos privados.
- Cuando el bridge está conectado, un cambio manual no necesita cerrar Codex ni esperar al final de toda la tarea. La petición de red que ya está abierta termina con la cuenta anterior y la siguiente petición de la misma tarea usa la nueva autenticación.
- Si el backend termina un turno con `usageLimitExceeded`, Switchboard cambia la cuenta en memoria y crea una continuación automática en el mismo hilo, conservando resultados y herramientas ya completadas. La continuación indica expresamente que no repita acciones anteriores.
- Los tokens externos nunca se escriben en órdenes, argumentos o registros del bridge. El bridge recibe únicamente la ruta privada del perfil, la valida contra los almacenes de Switchboard, lee el token en memoria y atiende la renovación solicitada por `account/chatgptAuthTokens/refresh` mediante el binario oficial.
- La UI distingue `Bridge conectado` de `En espera`. Si el protocolo experimental deja de responder, no se toca la autenticación persistente y se conserva el mecanismo de cierre seguro.
- Observa `thread_history_1.sqlite` cada 2 segundos, independientemente del refresco visual de cuotas. Un turno fallido con `codexErrorInfo: usageLimitExceeded` posterior a la activación confirma por sí solo el límite, aunque la API todavía muestre un porcentaje redondeado inferior al 100% consumido.
- Cada turno queda asociado a la cuenta que lo inició. Un aviso tardío de `usageLimitExceeded` refresca y bloquea esa cuenta original, pero nunca provoca una segunda rotación sobre la cuenta que ya está activa.
- Un `0% disponible` sin rechazo continúa tratándose como posible periodo de gracia y no provoca el cambio por sí solo.
- La cuenta activa recibe `account/rateLimits/updated` directamente del proceso vivo de Codex y actualiza la UI sin esperar al sondeo. Las cuentas inactivas se validan cada 15 segundos y siempre se releen antes de un cambio automático.
- Las barras muestran capacidad restante de 100 a 0. Los reinicios de ventana se actualizan cada segundo y se expresan con horas, minutos y segundos.
- Si una ventana guardada ya superó su fecha de restablecimiento, deja de considerarla agotada incluso antes de completar la siguiente consulta.
- Si todas las cuentas están agotadas, mantiene el estado de espera y revisa las candidatas cada 15 segundos. En cuanto alguna recupera uso, relee sus cuotas y cambia automáticamente cuando no haya una tarea real en curso.
- Un watchdog limita cada sondeo de `app-server`; si Codex no responde, la UI identifica el último dato válido y esa cuenta no se elige automáticamente hasta verificarla.
- El cambio de credenciales utiliza un diario transaccional. Si el Mac o la app se interrumpen entre movimientos, el siguiente arranque completa el cambio o restaura la cuenta anterior.
- El observador de inicio de Codex es persistente y dirigido por eventos; ya no arranca un proceso nuevo cada ocho segundos.
- Puede preparar automáticamente las ventanas limpias de cinco horas con una interacción efímera que responde únicamente `OK`. El experimento local confirmó que el nuevo `resetsAt` queda anclado cinco horas después aunque el consumo siga redondeando a 0%.
- La preparación vive en el agente `Pulse`, por lo que continúa con Switchboard y Codex cerrados mientras el Mac esté encendido y despierto; al volver del reposo ejecuta una comprobación inmediata.
- Antes de preparar una cuenta hace dos lecturas separadas para distinguir una ventana realmente limpia de un 0% ya anclado. Nunca interviene sobre la cuenta activa mientras Codex está abierto, no repite la sonda antes del `resetsAt` y valida que el modelo y el esfuerzo sigan disponibles.
- No aplica un umbral de reserva semanal: una cuenta con poco margen también participa. Solo evita la sonda cuando el límite semanal está literalmente al 100%, existe un bloqueo real, la sesión no se puede verificar o la ventana corta ya está en marcha.
- El modelo y el razonamiento son configurables desde la ficha de cualquier cuenta. Por defecto usa `gpt-5.6-luna` con `low`; la lista se obtiene dinámicamente mediante `model/list`, de modo que los modelos futuros pueden seleccionarse sin recompilar una lista fija.
- El estado por cuenta se guarda sin tokens ni conversaciones en `window-priming-state.json` y se muestra en la UI con la última decisión, modelo y siguiente reinicio.

## Conversaciones y límites del cambio en vivo

Las conversaciones están indexadas en el almacén local compartido de Codex y no incluyen una columna de cuenta, por lo que siguen visibles después del cambio. Con el bridge conectado, Switchboard cambia la autenticación del `app-server` vivo y después mueve atómicamente `auth.json` para que el siguiente inicio conserve la misma cuenta. Una conexión de modelo ya enviada no puede cambiar de propietario; el cambio se aplica a la siguiente petición interna. Sin bridge, Switchboard espera a que no haya trabajo real, cierra la app y usa el relevo transaccional anterior.

## Construcción

```zsh
chmod +x build.sh
./build.sh
node tests/test-hot-bridge.js "build/Codex Switchboard.app/Contents/Helpers/CodexHotBridge" tests/fake-codex.js
node tests/test-auxiliary-passthrough.js "build/Codex Switchboard.app/Contents/Helpers/CodexHotBridge" tests/fake-codex.js
```

La aplicación resultante queda en `build/Codex Switchboard.app`. No modifica `/Applications/ChatGPT.app` y usa siempre el binario `Contents/Resources/codex` que acompaña a la versión instalada.

Los scripts reutilizan una identidad `Apple Development` disponible para mantener estable el requisito designado de la aplicación entre actualizaciones. Esto reduce las reautorizaciones de Gestión de apps; un cambio de firma o identificador sí puede hacer que macOS vuelva a pedir permiso.

## Compatibilidad

La versión 0.3.9 se verificó con el protocolo local de Codex 0.151.0-alpha.7.2. Las pruebas del bridge cubren negociación, autenticación externa, multiplexado, renovación, actualizaciones inmediatas de cuota y avisos tardíos de límite ligados a su cuenta de origen. Los hosts auxiliares de Codex pasan directamente al binario oficial y no pueden reclamar el canal de control principal. El menú superior usa una instantánea precisa para evitar la recursión de SwiftUI que provoca `TimelineView` dentro de `MenuBarExtra` en macOS 26. La ficha mantiene segundos exactos; la lista lateral separa visualmente cada ventana, destaca el porcentaje y resume su reinicio solo con horas y minutos, también cuando la cuenta está agotada. Ajustes permite elegir Sistema, Español o English en caliente y controlar el cambio automático, el cambio en vivo y la preparación de ventanas.

## Idiomas y contribución

La aplicación incluye español e inglés y sigue automáticamente el idioma preferido de macOS. `AGENTS.md` exige que todo texto visible y toda modificación documental se mantengan en ambos idiomas; `scripts/check-localizations.js` bloquea la construcción si los catálogos divergen.
