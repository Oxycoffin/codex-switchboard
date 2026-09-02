# Codex Switchboard

**Usa varias cuentas de Codex como un único espacio de trabajo continuo en macOS.**

[Read in English](README.md)

Codex Switchboard mantiene preparadas tus cuentas de pago, muestra cuánto uso le queda a cada una y mueve Codex a una cuenta disponible cuando la actual alcanza su límite. Tus tareas, proyectos y conversaciones permanecen juntos en la app oficial de Codex.

## Qué aporta

- Una sola ventana de Codex y un historial de tareas compartido.
- Uso restante y tiempos de reinicio claros para todas las cuentas conectadas.
- Cambio automático cuando la cuenta activa se queda realmente sin uso.
- Cambio en vivo cuando el puente está disponible, con reinicio seguro como alternativa.
- Recuperación automática cuando todas estaban agotadas y una vuelve a estar disponible.
- Inicio y cierre de sesión, eliminación de cuentas, plan visible y acceso directo a su gestión.
- Preparación opcional de ventanas de cinco horas mientras el Mac está despierto.
- Una app nativa para la barra de menús, en español e inglés y sin icono en el Dock.

Switchboard entiende que no todos los planes muestran los mismos límites. Si un plan solo tiene una asignación semanal, se presenta como semanal; nunca como una ventana de cinco horas por ser el primer límite que entrega Codex.

## Cómo funciona

Codex sigue siendo la app que utilizas. Switchboard funciona a su lado y mantiene un perfil de inicio de sesión privado y aislado para cada cuenta. El espacio de trabajo local de Codex continúa compartido, por lo que cambiar la cuenta activa no crea otra copia de la app ni separa tus tareas.

Con el cambio en vivo activado, un puente externo se sitúa en la conexión estándar entre la interfaz de escritorio y el servicio de Codex incluido en la app. Reenvía el tráfico normal sin alterarlo y puede sustituir la autenticación activa en un límite seguro entre peticiones. Si un límite interrumpe una tarea, Switchboard puede continuarla en la misma tarea con la siguiente cuenta sin repetir el trabajo ya completado.

El puente es externo: Switchboard no parchea la aplicación de Codex, no edita `app.asar`, no sustituye el ejecutable oficial ni vuelve a firmar su paquete. Las actualizaciones de Codex se instalan con normalidad. Si una actualización cambia un contrato esencial, Switchboard muestra el fallo y conserva la alternativa basada en reinicio en lugar de modificar Codex.

## Uso básico

1. Abre Switchboard desde la barra de menús.
2. Añade cada cuenta mediante el acceso oficial de Codex.
3. Elige qué cuentas pueden participar en el cambio automático.
4. Deja activado el cambio automático o selecciona una cuenta manualmente cuando quieras.
5. Abre una cuenta para consultar su plan, límites, reinicios y acciones.

La cuenta que usa Codex se identifica en todo momento. La disponibilidad se muestra como capacidad restante, desde el 100% hasta el 0%.

## Privacidad y seguridad

Todos los perfiles permanecen en este Mac bajo `~/Library/Application Support/Codex Switchboard`, con permisos privados. Switchboard nunca solicita contraseñas ni guarda tokens en registros, órdenes, la interfaz o este repositorio. Tampoco copia ni indexa el contenido de las conversaciones.

Los perfiles del navegador para facturación están aislados por cuenta. No comparten cookies ni historial entre ellos ni con tu perfil habitual.

## Instalación

Codex Switchboard requiere actualmente macOS 14 o posterior y se distribuye desde el código fuente mientras el repositorio sea privado.

```zsh
chmod +x build.sh install.sh
./build.sh
./install.sh
```

La app se instala en `/Applications` y registra su asistente en segundo plano para el usuario actual. Mantener el mismo identificador y la misma firma ayuda a que macOS conserve el permiso de Gestión de apps entre actualizaciones.

## Idiomas

La interfaz está disponible en español e inglés. Puede seguir automáticamente el idioma de macOS o cambiarse al instante desde Ajustes.

## Para colaborar

Empieza por [Arquitectura](docs/ARCHITECTURE.md) para entender los procesos y los datos, y consulta [Contribuir](CONTRIBUTING.md) antes de modificar la app. Las normas de producto y localización del repositorio están en [AGENTS.md](AGENTS.md).

La app oficial de Codex debe permanecer intacta, los secretos de las cuentas nunca pueden quedar expuestos y todo cambio visible debe funcionar en español e inglés.
